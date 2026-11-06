# Offline stand-in for `hermes`, used by run-tests.ps1. It only mimics the calls Caduceus makes.
$a = @($args)
if ($a[0] -eq 'config') { if ($a[2] -eq 'model.default') { 'fake/model-a' }; exit 0 }
if ($a[0] -ne 'chat') { exit 2 }
$in = $a[[array]::IndexOf($a, '--in') + 1]
$prompt = Get-Content -Raw $a[[array]::IndexOf($a, '--query-file') + 1]
if ($env:FAKE_HERMES_LOG) { Set-Content $env:FAKE_HERMES_LOG $prompt }
Add-Content (Join-Path $in 'ok.txt') 'work'
if ($env:FAKE_HERMES_COMMIT -ne '0') {
  git -C $in add -A *> $null
  git -C $in -c user.name=fake -c user.email=fake@localhost commit -qm 'fake: work' *> $null
}
'{"type":"tool_use","name":"terminal","input":{"command":"echo working"}}'
'{"type":"result","exit_code":0,"duration_ms":1200,"text":"done","session_id":"fake-1","tokens":{"input":100,"cache_read":0,"output":10}}'
