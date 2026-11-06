# Offline tests: a fake `hermes` stands in for the real agent, so no model is called and nothing is billed.
# Run: pwsh -File tests/run-tests.ps1
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "caduceus-test-$PID"
New-Item -ItemType Directory $root | Out-Null
$env:Path = (Join-Path $PSScriptRoot 'fake-hermes') + ';' + $env:Path
$env:FAKE_HERMES_LOG = Join-Path $root 'prompt.log'
$cad = Join-Path $PSScriptRoot '..\caduceus.ps1'
$script:fail = 0
function Check($name, $cond) { if ($cond) { "ok   $name" } else { "FAIL $name"; $script:fail++ } }

try {
  $repo = Join-Path $root 'demo'
  git init -q $repo; Set-Content "$repo\README.md" 'demo'
  git -C $repo add -A; git -C $repo -c user.name=t -c user.email=t@localhost commit -qm init
  Set-Content "$root\TASK.md" 'Create ok.txt. It is for a hyperframes project.'
  $cfg = Join-Path $root 'cfg.json'
  @{ preflight = $false
     ram = @{ gateGB = 0; cleanOrphanBrowsers = $false; cleanHermesLsp = $false }
     fitRules = @(@{ pattern = '(?i)hyperframes'; level = 'FIT WARNING'; message = 'test rule' }) } |
    ConvertTo-Json -Depth 4 | Set-Content $cfg
  $wt = Join-Path $root '_hermes-wt\demo-t1'

  $out = pwsh -NoProfile -File $cad -Repo $repo -Name t1 -Task "$root\TASK.md" -Test 'type ok.txt' -Config $cfg *>&1 | Out-String
  Check 'new task exits 0' ($LASTEXITCODE -eq 0)
  Check 'fit rule warns' ($out -match 'FIT WARNING: test rule')
  Check 'new commit reported' ($out -match 'fake: work')
  Check 'worktree on its own branch' ((git -C $wt branch --show-current) -eq 'hermes/t1')
  Check 'main checkout untouched' (-not (Test-Path "$repo\ok.txt"))

  $env:FAKE_HERMES_COMMIT = '0'
  $out = pwsh -NoProfile -File $cad -Repo $repo -Name t1 -Revise 'Add one more line.' -Config $cfg *>&1 | Out-String
  $env:FAKE_HERMES_COMMIT = $null
  Check 'revision exits 0' ($LASTEXITCODE -eq 0)
  Check 'revision prompt carries original task' ((Get-Content -Raw $env:FAKE_HERMES_LOG) -match '(?s)ORIGINAL TASK.*Create ok.txt.*Add one more line')
  Check 'uncommitted work gets a safety commit' ($out -match 'SAFETY COMMIT')
  Check 'worktree clean afterwards' (-not (git -C $wt status --porcelain))

  pwsh -NoProfile -File $cad -Repo $root -Name t2 -Task "$root\TASK.md" -Config $cfg *> $null
  Check 'non-git folder is refused' ($LASTEXITCODE -eq 1)
} finally {
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
"`n$(if ($script:fail) { "$($script:fail) check(s) failed" } else { 'all checks passed' })"
exit $script:fail
