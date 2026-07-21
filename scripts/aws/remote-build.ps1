# remote-build.ps1 - run ON the Chromium build box, sent by build-box.yml over SSM (browser#45).
#
# ASCII ONLY. Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so a stray em dash or box
# character here corrupts the parse with a misleading "Missing closing '}'". Verified the hard
# way on this box. Same rule the manual runbook has for C:\build\do_build.ps1.
#
# WHY THIS EXISTS. SSM RunCommand executes as NT AUTHORITY\SYSTEM, but depot_tools must run
# as Administrator (box golden rule). The `crbuild` scheduled task is registered
# `Run As User: Administrator` and runs `powershell -File C:\build\do_build.ps1`, which is the
# path every release has actually been built with. So CI must TRIGGER that task rather than
# invoke do_build.ps1 directly.
#
# The catch: `schtasks /Run` returns as soon as the task is *launched*, so a naive trigger
# reports success instantly with no build. Hence the marker protocol below.
#
# MARKER CONTRACT (set by do_build.ps1, not by us):
#   C:\build\<job>.done    written LAST - "DONE" on success, "ERROR: <msg>" on failure
#   C:\build\<job>.status  progress lines, appended as the build moves through stages
#   C:\build\<job>.log     full build log
# We delete <job>.done up front so a stale marker from a previous run cannot be read as this
# run's verdict (do_build.ps1 also deletes it, but only once it has actually started).
#
# EXIT CODES: 0 build OK / 1 build reported ERROR / 2 task never started / 3 timed out.
# These are explicit because a PowerShell script that merely *prints* an error still leaves
# SSM reporting Status=Success - verified on this box, where two command-not-found errors
# came back as a green invocation.

[CmdletBinding()]
param(
  [string]$TaskName       = 'crbuild',
  [string]$Job            = 'official18',
  [int]   $TimeoutMinutes = 180,
  [string]$BuildDir       = 'C:\build'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$done   = Join-Path $BuildDir "$Job.done"
$status = Join-Path $BuildDir "$Job.status"

function Show-StatusTail {
  if (Test-Path $status) {
    Write-Output "--- $Job.status (tail) ---"
    Get-Content $status -Tail 25 | ForEach-Object { Write-Output $_ }
  }
}

Write-Output "task=$TaskName job=$Job timeout=${TimeoutMinutes}m"
Remove-Item $done -ErrorAction SilentlyContinue

# Trigger the Administrator-context task.
schtasks /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Output "ERROR: schtasks /Run /TN $TaskName failed ($LASTEXITCODE)"
  exit 2
}

# Confirm it actually entered Running. Without this a mis-registered or disabled task looks
# identical to an instant success.
$started = $false
for ($i = 0; $i -lt 60; $i++) {
  if (Test-Path $done) { $started = $true; break }
  $q = schtasks /Query /TN $TaskName /FO LIST 2>$null
  if ($q -match 'Status:\s+Running') { $started = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $started) {
  Write-Output "ERROR: $TaskName never entered Running - check schtasks /Query /TN $TaskName /V /FO LIST"
  exit 2
}
Write-Output "$TaskName running; waiting for $Job.done"

# Poll the marker.
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastNote = Get-Date
while (-not (Test-Path $done)) {
  if ((Get-Date) -gt $deadline) {
    Write-Output "ERROR: timed out after $TimeoutMinutes minutes waiting for $done"
    Show-StatusTail
    exit 3
  }
  # A heartbeat every 5 min keeps the SSM invocation visibly alive during a ~90 min build.
  if (((Get-Date) - $lastNote).TotalMinutes -ge 5) {
    $lastNote = Get-Date
    if (Test-Path $status) {
      Write-Output ("  [" + (Get-Date -Format HH:mm:ss) + "] " + (Get-Content $status -Tail 1))
    }
  }
  Start-Sleep -Seconds 30
}

$verdict = (Get-Content $done -Raw).Trim()
Show-StatusTail
if ($verdict -ne 'DONE') {
  Write-Output "ERROR: build reported: $verdict"
  exit 1
}
Write-Output 'BUILD OK'
exit 0
