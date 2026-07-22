# do_rebase.ps1 - rebase the Chromium checkout onto a target tag and re-apply the
# inline-3D patch series. Runs ON the build box, as Administrator (via the crbuild
# scheduled task), staged there by scripts/aws/remote-rebase.ps1.
#
# ASCII ONLY (Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI; an em dash produces a
# bogus "Missing closing '}'"). Same rule as do_build.ps1 / remote-build.ps1 (#45).
#
# This is the repo-canonical copy of the script that previously lived only on the box.
# Versioning it here is part of #36: an un-tracked rebase script silently drifts from the
# patch series it applies.
#
# TARGET TAG: read from $env:DXR_TARGET_TAG. remote-rebase.ps1 injects it by prepending
# an assignment before staging this file, because a crbuild-launched task does NOT inherit
# the env of the SSM session that triggered it. Falls back to the config pin if unset.
#
# MARKER CONTRACT (polled by remote-rebase.ps1):
#   C:\build\rebase.done  written LAST: "OK <tag> <describe>" clean, or "ERROR: <msg>"
#   C:\build\rebase.log   full log
# A `git am` failure is the drift gate: abort and STOP. Do NOT proceed to a build - the
# series needs a manual rebase (#36) and a human eyeball.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$env:Path = 'C:\depot_tools;C:\git\cmd;' + $env:Path
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
$env:DEPOT_TOOLS_UPDATE        = '0'

$TAG = $env:DXR_TARGET_TAG
if (-not $TAG) { $TAG = '150.0.7871.129' }
$LOG  = 'C:\build\rebase.log'
$DONE = 'C:\build\rebase.done'
Remove-Item $DONE -ErrorAction SilentlyContinue
Remove-Item $LOG  -ErrorAction SilentlyContinue

function Stage($m){ "=== $m ===" | Tee-Object -FilePath $LOG -Append }
function Fail($m){ Stage "ERROR: $m"; "ERROR: $m" | Out-File $DONE -Encoding ascii; exit 1 }

Stage "rebase to $TAG starting"

# 1. Discard the working tree. The patch series in patches/ is canonical, so dirty files
#    are disposable.
cmd /c "cd /d C:\cr\src && git checkout -- . >> $LOG 2>&1"
cmd /c "cd /d C:\cr\src && git reset --hard >> $LOG 2>&1"
Stage 'working tree reset'

# 2. Fetch + check out the target tag.
cmd /c "cd /d C:\cr\src && git fetch --tags --depth=1 origin tag $TAG >> $LOG 2>&1"
if ($LASTEXITCODE -ne 0) { cmd /c "cd /d C:\cr\src && git fetch --tags origin >> $LOG 2>&1" }
cmd /c "cd /d C:\cr\src && git checkout -f $TAG >> $LOG 2>&1"
if ($LASTEXITCODE -ne 0) { Fail "checkout $TAG" }
Stage "checked out $TAG"

# 3. gclient sync to match the tag (run from the .gclient root).
cmd /c "cd /d C:\cr && gclient sync -D --force --reset --nohooks >> $LOG 2>&1"
if ($LASTEXITCODE -ne 0) { Fail 'gclient sync' }
Stage 'gclient sync OK'
cmd /c "cd /d C:\cr && gclient runhooks >> $LOG 2>&1"
Stage 'runhooks done'

# 4. Re-apply the inline-3D patch series. THE DRIFT GATE: if `git am` fails the series
#    needs a manual rebase (#36) and we must NOT proceed to a build.
$patches = Get-ChildItem 'C:\build\patches\*.patch' | Sort-Object Name
if (-not $patches) { Fail 'no patches found at C:\build\patches' }
Stage ("applying " + $patches.Count + " patches")
$list = ($patches | ForEach-Object { '"' + $_.FullName + '"' }) -join ' '
cmd /c "cd /d C:\cr\src && git am --3way --keep-non-patch $list >> $LOG 2>&1"
if ($LASTEXITCODE -ne 0) {
  # Capture the failing patch before aborting, so the CI job can name it.
  $failing = (cmd /c "cd /d C:\cr\src && git am --show-current-patch=raw 2>nul | findstr /b Subject")
  if ($failing) { Stage "FAILING PATCH: $failing" }
  cmd /c "cd /d C:\cr\src && git am --abort >> $LOG 2>&1"
  Fail "patch series did not apply cleanly on $TAG (rebase needed - #36)"
}
Stage 'patch series applied cleanly'

$desc = (cmd /c "cd /d C:\cr\src && git describe --tags").Trim()
Stage "HEAD = $desc"
"OK $TAG $desc" | Out-File $DONE -Encoding ascii
Stage 'REBASE DONE'
