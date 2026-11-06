<#
Caduceus: a bridge that lets Claude Code delegate work to Hermes Agent.

Claude writes a task, Caduceus runs Hermes on it inside an isolated git worktree,
watches it, enforces a time limit, and reports back commits, diff, test result and RESULT.md.

Copyright (c) 2026 Fuad Nurhadi (fuadnurhadi.my.id). MIT License.

Examples:
  pwsh -File caduceus.ps1 -Repo C:\repo -Task C:\tmp\TASK.md -Name fix-login -Test "npm test"
  pwsh -File caduceus.ps1 -Repo C:\repo -Name fix-login -Revise "Test X still fails: ..."   # fresh, cheap revision
  pwsh -File caduceus.ps1 ... -Resume <session_id> -Revise "..."                            # continue old session (expensive)
#>
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$Name,
  [string]$Task,
  [string]$Test,
  [int]$MaxTurns = 200,
  [int]$TimeoutMin = 30,
  [string[]]$Model,
  [string]$Toolset = 'coding',     # NOT "Profile": that collides with PowerShell's automatic $PROFILE variable
  [string]$Base,
  [string]$Resume,
  [string]$Revise,
  [string]$Config
)
$ErrorActionPreference = 'Stop'
$env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')   # finds a freshly installed hermes in a stale shell

# Write-Host, not Write-Output: inside a function Write-Output becomes part of the return value.
function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
function Stop-Run($msg) { Say "STOP: $msg"; exit 1 }
function Free-GB { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }

# ---------- Configuration ----------
$defaults = [ordered]@{
  preflight = $true                # ping each model before starting; false = trust the list as is
  endpoint = $null                 # OpenAI-compatible base URL; null = Hermes `model.base_url`
  apiKeyEnv = 'CADUCEUS_API_KEY'   # env var with the key used for the pre-flight ping
  readKeyFromHermesConfig = $true  # fallback: read api_key from Hermes config.yaml
  models = @()                     # fallback order; empty = Hermes `model.default` only
  toolsets = @{ coding = 'terminal,file,todo'; video = 'terminal,file,todo,skills'; full = '' }
  branchPrefix = 'hermes/'
  worktreeDir = '_hermes-wt'
  resultFile = 'RESULT.md'
  ram = @{ gateGB = 1.5; cleanupBelowGB = 2.0; cleanOrphanBrowsers = $true; cleanHermesLsp = $true }
  router = @{ port = $null; startCommand = $null }
  fitRules = @()
}
$cfgPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'caduceus.config.json' }
$C = $defaults
if (Test-Path $cfgPath) {
  $user = Get-Content -Raw $cfgPath | ConvertFrom-Json -AsHashtable
  foreach ($k in $user.Keys) {
    if ($C[$k] -is [hashtable] -and $user[$k] -is [hashtable]) { foreach ($kk in $user[$k].Keys) { $C[$k][$kk] = $user[$k][$kk] } }
    else { $C[$k] = $user[$k] }
  }
}
if (-not $C.toolsets.ContainsKey($Toolset)) { Stop-Run "unknown toolset '$Toolset' (known: $($C.toolsets.Keys -join ', '))" }

$PROVIDER_FAILURE = 'credits|afford|budget|ExceededBudget|No active credentials|Unknown model|model_not_found|grown too long|APIConnectionError|payload is not completed|\b(401|402|403|404|422|429)\b'

function Clear-Ram {
  # Only processes that are safe to stop: headless browsers whose owner has exited (leftovers of
  # render/preview tools), and Hermes's helper language servers (restarted on demand).
  $ids = @()
  if ($C.ram.cleanOrphanBrowsers) {
    $all = Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'chrome' }
    $ids += foreach ($p in ($all | Where-Object { $_.CommandLine -match 'headless|remotion|hyperframes|puppeteer' })) {
      $root = $p
      for ($i = 0; $i -lt 6; $i++) { $par = $all | Where-Object ProcessId -eq $root.ParentProcessId; if ($par) { $root = $par } else { break } }
      if (-not (Get-Process -Id $root.ParentProcessId -ErrorAction SilentlyContinue)) { $p.ProcessId }
    }
  }
  if ($C.ram.cleanHermesLsp) { $ids += (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'hermes\\lsp\\node_modules' }).ProcessId }
  $ids = @($ids | Where-Object { $_ } | Sort-Object -Unique)
  $ids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
  return $ids.Count
}

function Test-Model($url, $key, $mdl, $cap) {
  # Streaming, with the same max_tokens Hermes sends: some gateways return an empty body for
  # non-stream calls, and some only reject (402) once the full output budget is requested.
  $b = @{ model = $mdl; stream = $true; messages = @(@{ role = 'user'; content = 'Reply: ok' }) }
  if ($cap -match '^\d+$') { $b.max_tokens = [int]$cap }
  $tmp = Join-Path $env:TEMP "caduceus-ping-$PID.json"; Set-Content $tmp ($b | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
  $o = (curl.exe -s -m 90 "$url/chat/completions" -H "Authorization: Bearer $key" -H "Content-Type: application/json" --data-binary "@$tmp") -join ''
  Remove-Item $tmp -ErrorAction SilentlyContinue
  if ($o -match '"content":"') { return $null }
  # Routers wrap the upstream error as escaped JSON inside their own; the innermost message is the useful one.
  $err = @([regex]::Matches(($o -replace '\\+"', '"'), '"message":"([^"]{1,160})') | ForEach-Object { $_.Groups[1].Value })[-1]
  return $(if ($err) { $err } else { 'empty response' })
}

# ---------- 1. Pre-flight ----------
if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) { Stop-Run "hermes not found on PATH" }
$Repo = (Resolve-Path $Repo).Path
git -C $Repo rev-parse --git-dir *> $null; if ($LASTEXITCODE) { Stop-Run "$Repo is not a git repository" }
if (-not $Resume -and -not $Task -and -not $Revise) { Stop-Run "need -Task (new task) or -Revise (revision)" }
if ($Resume -and -not $Revise) { Stop-Run "-Resume needs -Revise" }

if ($C.router.port -and -not (Get-NetTCPConnection -LocalPort $C.router.port -State Listen -ErrorAction SilentlyContinue)) {
  if (-not $C.router.startCommand) { Stop-Run "router on port $($C.router.port) is not running" }
  Say "router is down, starting: $($C.router.startCommand)"
  Start-Process cmd.exe -ArgumentList '/c', $C.router.startCommand -WindowStyle Hidden
  $t = 0; while (-not (Get-NetTCPConnection -LocalPort $C.router.port -State Listen -ErrorAction SilentlyContinue) -and $t -lt 40) { Start-Sleep 2; $t += 2 }
  if ($t -ge 40) { Stop-Run "router did not start within 40 s" }
}

# -Model accepts a PowerShell array or one comma-separated string (pwsh -File does not split arrays).
$candidates = if ($Model) { @($Model | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim(' ', '"', "'") } | Where-Object { $_ }) }
              elseif ($C.models) { @($C.models) } else { @(hermes config get model.default) }
$ready = @(); $skipped = @()
if (-not $C.preflight) { $ready = $candidates }
else {
  $routerUrl = if ($C.endpoint) { $C.endpoint } else { hermes config get model.base_url }   # never name this $base: PS is case-insensitive
  $key = [Environment]::GetEnvironmentVariable($C.apiKeyEnv)
  if (-not $key -and $C.readKeyFromHermesConfig) {
    $raw = Get-Content -Raw (hermes config path)
    $key = if ($raw -match '(?ms)^providers:.*?api_key:\s*"?([^"\r\n#]+?)"?\s*$') { $Matches[1] } elseif ($raw -match '(?ms)^model:.*?^\s+api_key:\s*"?([^"\r\n#]+?)"?\s*$') { $Matches[1] } else { '' }
  }
  $cap = hermes config get "providers.$(hermes config get model.provider).extra_body.max_tokens" 2>$null
  foreach ($m in $candidates) { $e = Test-Model $routerUrl $key $m $cap; if ($e) { $skipped += "$m -> $e" } else { $ready += $m } }
}
if (-not $ready) { Stop-Run ("no model answered:`n  " + ($skipped -join "`n  ") + "`n  (credits/budget errors: top up the provider behind your router)") }
if ($skipped) { Say ("skipped models: " + ($skipped -join ' | ')) }
Say "model: $($ready[0])$(if ($ready.Count -gt 1) { " (fallbacks: $($ready[1..($ready.Count-1)] -join ', '))" })"

# ---------- 2. Worktree ----------
$branch = "$($C.branchPrefix)$Name"
$wt = Join-Path (Split-Path $Repo) (Join-Path $C.worktreeDir ((Split-Path $Repo -Leaf) + "-$Name"))
if (-not (Test-Path $wt)) {
  if ($Revise -and -not $Task) { Stop-Run "a revision needs an existing worktree: $wt" }
  if (-not $Base) {
    git -C $Repo fetch -q origin 2>$null
    $Base = git -C $Repo symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if (-not $Base) { $Base = 'HEAD' }   # no remote: git prints an empty string, not $null
  }
  $o1 = git -C $Repo worktree add -q --no-track -b $branch $wt $Base 2>&1
  if ($LASTEXITCODE) { $o2 = git -C $Repo worktree add -q $wt $branch 2>&1 }
  if ($LASTEXITCODE) { Stop-Run "could not create worktree $wt (base=$Base): $((@($o1) + @($o2) | ForEach-Object { "$_" }) -join ' | ')" }
  Say "new branch from $Base"
}
$startRef = git -C $wt rev-parse HEAD
Say "worktree: $wt (branch $branch), toolset: $Toolset"

# ---------- Task fit check ----------
$taskText = "$(if ($Task) { Get-Content -Raw $Task }) $Revise"
foreach ($r in $C.fitRules) { if ($taskText -match $r.pattern) { Say "$($r.level): $($r.message)"; break } }

# ---------- 3. Prompt ----------
$work = Join-Path $env:TEMP "caduceus\$Name"; New-Item -ItemType Directory -Force $work | Out-Null
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$rules = @"
You are the executor. Work ONLY inside the folder $wt (git branch $branch).
Rules: do not push, do not switch branches, do not edit .env files or deployment configuration, do not run production database migrations.
Commit your work to this branch with clear messages. When done, write $($C.resultFile) in the root of that folder (what changed, test results, what is unfinished) and commit it too.
Write code comments and $($C.resultFile) in the same language as the task.
"@
if ($Task) { Copy-Item $Task (Join-Path $work 'TASK-original.md') -Force }
$original = Join-Path $work 'TASK-original.md'
function New-Prompt($mode, $note) {
  $body = switch ($mode) {
    'new' { Get-Content -Raw $Task }
    'resume' { "REVISION from the reviewer:`n$Revise" }
    'revise' {
      $fork = git -C $wt merge-base HEAD (git -C $Repo rev-parse HEAD) 2>$null
      $diff = (git -C $wt diff --stat $fork 2>$null | Out-String)
      $log = (git -C $wt log --oneline -8 | Out-String)
      "ORIGINAL TASK (already partly or fully done on this branch):`n" + $(if (Test-Path $original) { Get-Content -Raw $original } else { '(not saved)' }) +
      "`n`nRECENT COMMITS:`n$log`nFILES CHANGED SO FAR:`n$diff`nREVISION from the reviewer (do only this, do not start over):`n$Revise"
    }
    'continue' { "The previous session stopped because of a model provider problem ($note). Check the branch state (git status, git log, existing files), then CONTINUE this task to completion without starting over:`n`n" + $(if (Test-Path $original) { Get-Content -Raw $original } else { $Revise }) }
  }
  $f = Join-Path $work "prompt-$stamp-$mode.md"; Set-Content -Encoding UTF8 $f "$rules`n`n$body"; return $f
}

# ---------- 4. Run (RAM gate, RAM cleanup, time limit) ----------
function Invoke-Hermes($mdl, $prompt, $resumeId, $label) {
  $t = 0
  while ((Free-GB) -lt $C.ram.gateGB -and $t -lt 900) {
    if ($t % 60 -eq 0) { $n = Clear-Ram; Say ("waiting for free RAM >= {0} GB (free {1:N1} GB, cleaned {2} processes)" -f $C.ram.gateGB, (Free-GB), $n) }
    Start-Sleep 10; $t += 10
  }
  $log = Join-Path $work "run-$stamp-$label.jsonl"
  $hargs = @('chat', '--in', $wt, '--source', 'tool', '--format', 'stream-json', '--query-file', $prompt)
  if ($resumeId) { $hargs += @('--resume', $resumeId) }      # a resumed session keeps its original settings
  else {
    $hargs += @('--checkpoints', '--max-turns', $MaxTurns, '-m', $mdl)
    if ($C.toolsets[$Toolset]) { $hargs += @('-t', $C.toolsets[$Toolset]) }
  }
  # Start-Process does not quote arguments that contain spaces.
  $hargs = @($hargs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } })
  $p = Start-Process (Get-Command hermes).Source -ArgumentList $hargs -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
  Say "Hermes running ($label, $mdl, pid $($p.Id)), limit $TimeoutMin min, log $log"
  $seen = 0; $deadline = (Get-Date).AddMinutes($TimeoutMin); $res = $null; $steps = 0; $tick = 0
  while ($true) {
    $done = $p.HasExited
    $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
    $fresh = if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] } else { @() }   # PS ranges count down when empty
    foreach ($l in $fresh) {
      if (-not $l -or $l[0] -ne '{') { continue }
      $ev = $l | ConvertFrom-Json -ErrorAction SilentlyContinue; if (-not $ev) { continue }
      if ($ev.type -eq 'tool_use') {
        $steps++
        $arg = ($ev.input.command ?? $ev.input.path ?? $ev.input.query ?? '') -replace '\s+', ' '
        Say ("step {0}: {1} {2}" -f $steps, $ev.name, $arg.Substring(0, [Math]::Min(110, $arg.Length)))
      } elseif ($ev.type -eq 'result') { $res = $ev }
    }
    $seen = $lines.Count
    if ($done) { break }
    if ((Get-Date) -gt $deadline) { Say "TIME LIMIT $TimeoutMin min reached, stopping Hermes"; taskkill /PID $p.Id /T /F *> $null; break }
    if (++$tick % 6 -eq 0 -and (Free-GB) -lt $C.ram.cleanupBelowGB) { $n = Clear-Ram; Say ("low RAM, cleaned {0} processes (free {1:N1} GB)" -f $n, (Free-GB)) }
    Start-Sleep 5
  }
  return [pscustomobject]@{ res = $res; steps = $steps; log = $log; model = $mdl }
}

$mode = if ($Resume) { 'resume' } elseif ($Revise) { 'revise' } else { 'new' }
$run = Invoke-Hermes $ready[0] (New-Prompt $mode '') $Resume $mode
$rounds = @($run)
# Continue once on the next model when the failure came from the provider, not the task.
$why = "$($run.res.error) $($run.res.text)"
if (($run.res.exit_code -ne 0) -and ($why -match $PROVIDER_FAILURE) -and $ready.Count -gt 1) {
  $short = ($why -replace '\s+', ' ').Substring(0, [Math]::Min(120, $why.Length))
  Say "PROVIDER FAILURE on $($ready[0]): $short -> continuing on $($ready[1])"
  $run = Invoke-Hermes $ready[1] (New-Prompt 'continue' $short) $null 'continue'
  $rounds += $run
}

# ---------- 5. Safety-net commit ----------
$dirty = git -C $wt status --porcelain | Where-Object { $_ -notmatch 'node_modules' }
if ($dirty) {
  git -C $wt add -A 2>&1 | Out-Null
  git -C $wt -c user.name="Hermes (via Caduceus)" -c user.email="hermes@localhost" commit -qm "hermes: uncommitted work saved by Caduceus" 2>&1 | Out-Null
  Say "SAFETY COMMIT: $(@($dirty).Count) file(s) left uncommitted by Hermes were committed"
}
$n = Clear-Ram; if ($n) { Say "final cleanup: stopped $n orphan/helper processes" }

# ---------- Report ----------
Write-Output "`n===== HERMES RESULT ====="
foreach ($r in $rounds) {
  $x = $r.res
  if ($x) {
    $txt = $x.text; if (-not $txt -and $x.error) { $txt = "HERMES ERROR: $($x.error)" }
    if ("$txt" -match 'grown too long|credits|afford|budget') { $txt = "[likely out of provider credit, check your router] $txt" }
    Write-Output ("[{0}] exit={1} duration={2}s steps={3} tokens_in={4} cache_read={5} tokens_out={6}" -f $r.model, $x.exit_code, [int]($x.duration_ms / 1000), $r.steps, $x.tokens.input, $x.tokens.cache_read, $x.tokens.output)
    Write-Output "session_id=$($x.session_id)"
    Write-Output "final answer: $txt"
  } else { Write-Output "[$($r.model)] no result event (stopped or crashed). stderr:"; Get-Content "$($r.log).err" -Tail 10 -ErrorAction SilentlyContinue }
}
Write-Output "`n--- new commits on $branch"; git -C $wt log --oneline "$startRef..HEAD" 2>$null
Write-Output "`n--- changes since start"; git -C $wt diff --stat $startRef 2>$null
$code = 0
if ($Test) {
  Write-Output "`n--- test: $Test"
  Push-Location $wt; try { $out = cmd /c "$Test 2>&1"; $code = $LASTEXITCODE } finally { Pop-Location }
  $out | Select-Object -Last 25; Write-Output "test exit=$code"
}
$rf = Join-Path $wt $C.resultFile
if (Test-Path $rf) { Write-Output "`n--- $($C.resultFile)"; Get-Content $rf -TotalCount 60 }
Write-Output "`nworktree=$wt"
$last = $rounds[-1].res
if (-not $last -or $last.exit_code -ne 0 -or ($Test -and $code -ne 0)) { exit 1 }
