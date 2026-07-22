# remote-rebase.ps1 - run ON the build box, sent by pipeline.yml/build-box.yml over SSM.
# Drives do_rebase.ps1 as Administrator and reports a clean/conflict verdict (#36).
#
# ASCII ONLY (see remote-build.ps1 / #45).
#
# WHY LIKE remote-build.ps1. Same constraints: depot_tools/gclient must run as
# Administrator, not SSM's SYSTEM; the crbuild scheduled task provides that; schtasks /Run
# returns on launch so we poll a marker; and SSM reports Success even for a script that
# only PRINTS an error, so the verdict must be an explicit exit code.
#
# TAG INJECTION. do_rebase.ps1 reads $env:DXR_TARGET_TAG, but a crbuild-launched task does
# NOT inherit this SSM session's env. So we STAGE the rebase script as do_build.ps1 (what
# crbuild runs) with an assignment prepended, rather than relying on the env crossing the
# task boundary. do_build.ps1 is backed up first and restored in a finally.
#
# EXIT CODES: 0 clean apply / 1 patch conflict (drift, human needed) / 2 task never
# started / 3 timed out.

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Tag,
  [string]$TaskName       = 'crbuild',
  [int]   $TimeoutMinutes = 60,
  [string]$BuildDir       = 'C:\build',
  [string]$RebaseScript   = 'C:\build\do_rebase.ps1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$done   = Join-Path $BuildDir 'rebase.done'
$log    = Join-Path $BuildDir 'rebase.log'
$target = Join-Path $BuildDir 'do_build.ps1'
$backup = Join-Path $BuildDir 'do_build.ps1.prebuild-backup'

function Show-LogTail {
  if (Test-Path $log) {
    Write-Output '--- rebase.log (tail) ---'
    Get-Content $log -Tail 30 | ForEach-Object { Write-Output $_ }
  }
}

Write-Output "rebase tag=$Tag task=$TaskName timeout=${TimeoutMinutes}m"
if (-not (Test-Path $RebaseScript)) { Write-Output "ERROR: no rebase script at $RebaseScript"; exit 2 }

# Stage the rebase script as do_build.ps1 with the tag injected, backing up the build
# script first so a later build step still has it.
if (-not (Test-Path $backup)) { Copy-Item $target $backup -Force -ErrorAction SilentlyContinue }
$body = "`$env:DXR_TARGET_TAG = '$Tag'`r`n" + (Get-Content $RebaseScript -Raw)
Set-Content -Path $target -Value $body -Encoding ascii
Remove-Item $done -ErrorAction SilentlyContinue

try {
  schtasks /Run /TN $TaskName | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Output "ERROR: schtasks /Run /TN $TaskName failed ($LASTEXITCODE)"; exit 2 }

  $started = $false
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-Path $done) { $started = $true; break }
    $q = schtasks /Query /TN $TaskName /FO LIST 2>$null
    if ($q -match 'Status:\s+Running') { $started = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $started) { Write-Output "ERROR: $TaskName never entered Running"; exit 2 }
  Write-Output "$TaskName running; waiting for rebase.done"

  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $lastNote = Get-Date
  while (-not (Test-Path $done)) {
    if ((Get-Date) -gt $deadline) { Write-Output "ERROR: rebase timed out after $TimeoutMinutes min"; Show-LogTail; exit 3 }
    if (((Get-Date) - $lastNote).TotalMinutes -ge 3) {
      $lastNote = Get-Date
      if (Test-Path $log) { Write-Output ("  [" + (Get-Date -Format HH:mm:ss) + "] " + (Get-Content $log -Tail 1)) }
    }
    Start-Sleep -Seconds 20
  }

  $verdict = (Get-Content $done -Raw).Trim()
  Show-LogTail
  if ($verdict -like 'OK *') { Write-Output "REBASE OK: $verdict"; exit 0 }
  Write-Output "CONFLICT: $verdict"
  exit 1
}
finally {
  # Restore the build script so a subsequent build step runs the real do_build.ps1.
  if (Test-Path $backup) { Copy-Item $backup $target -Force }
}
