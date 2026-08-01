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

# Stage() must write ASCII, NOT Tee-Object.
#
# Tee-Object on Windows PowerShell 5.1 writes UTF-16LE with a BOM, while every
# `cmd /c "... >> $LOG"` in this script appends plain ANSI. That makes rebase.log
# a MIXTURE of two encodings, and Get-Content decodes the whole file by the
# leading BOM - so remote-rebase.ps1's progress line ("last line of the log")
# came back as mojibake and stopped advancing regardless of real progress.
#
# The cost of that was not cosmetic: it is why three consecutive runs could not be
# diagnosed. We could see that the rebase was slow but not WHERE, and the one line
# we could see was unreadable. Write-Output for the console, Add-Content -Encoding
# ascii for the file, so the whole log is single-encoding and tailable.
function Stage($m){
  $line = "=== $m ==="
  Write-Output $line
  Add-Content -Path $LOG -Value $line -Encoding ascii
}
function Fail($m){ Stage "ERROR: $m"; "ERROR: $m" | Out-File $DONE -Encoding ascii; exit 1 }

Stage "rebase to $TAG starting"

# 0. Sync the canonical patch series from the repo into C:\build\patches.
#
#    That directory used to be populated by hand. Nothing in build-box.yml ever shipped
#    patches/ to the box, so the lane could only ever re-apply whatever series someone had
#    last copied there: a NEW patch could not be built through CI at all, and the series
#    the box applied could silently drift from the repo it came from - the same drift #36
#    called out for the rebase script itself, which is why that script is now versioned
#    here. Pulling the series over git closes the loop and needs no new AWS permissions
#    (the repo is public) and no SSM payload (the series is ~3.5 MB, far past the
#    RunCommand limit, so staging it inline was never an option).
#
#    Done BEFORE the tag checkout and gclient sync so a bad ref fails in seconds rather
#    than after tens of minutes of syncing.
$PATCH_REF = $env:DXR_PATCH_REF
if (-not $PATCH_REF) { $PATCH_REF = 'main' }
$REPO_URL  = 'https://github.com/DisplayXR/displayxr-browser.git'
$REPO_DIR  = 'C:\build\displayxr-browser'
$PATCH_DIR = 'C:\build\patches'

# NO GIT HERE. The first version of this used `git clone` + `git fetch`, and it
# HUNG - three runs burned their whole budget with rebase.log containing nothing
# but the "starting" marker while a git process sat there never returning. Under
# the crbuild scheduled task there is no console, so anything git decides to
# prompt for (a credential helper popping UI, a host-key question) blocks
# forever, and a hang is indistinguishable from slow work.
#
# A patch series is just files. Fetch them over plain HTTPS as a zip: no
# credential helper, no interactive anything, an explicit timeout, and a hard
# failure instead of an infinite wait.
$ZIP = 'C:\build\patchsrc.zip'
$EXT = 'C:\build\patchsrc'
Remove-Item $ZIP -Force -ErrorAction SilentlyContinue
Remove-Item $EXT -Recurse -Force -ErrorAction SilentlyContinue

# codeload wants refs/heads/<branch> for a branch, but a bare SHA for a commit.
if ($PATCH_REF -match '^[0-9a-fA-F]{40}$') { $refPath = $PATCH_REF }
else { $refPath = "refs/heads/$PATCH_REF" }
$URL = "https://codeload.github.com/DisplayXR/displayxr-browser/zip/$refPath"
Stage "downloading patch series from $URL"
try {
    $ProgressPreference = 'SilentlyContinue'   # progress UI is slow and useless here
    Invoke-WebRequest -Uri $URL -OutFile $ZIP -UseBasicParsing -TimeoutSec 300
} catch {
    Fail ("download failed for ref '" + $PATCH_REF + "': " + $_.Exception.Message)
}
if (-not (Test-Path $ZIP)) { Fail "no zip downloaded for ref '$PATCH_REF'" }
Stage ("downloaded " + [math]::Round((Get-Item $ZIP).Length/1KB) + " KB")

try { Expand-Archive -Path $ZIP -DestinationPath $EXT -Force }
catch { Fail ("expand failed: " + $_.Exception.Message) }

$srcDir = Get-ChildItem $EXT -Directory | Select-Object -First 1
if (-not $srcDir) { Fail "zip contained no top-level directory" }
$srcPatches = @(Get-ChildItem (Join-Path $srcDir.FullName 'patches\*.patch') -ErrorAction SilentlyContinue)
if ($srcPatches.Count -eq 0) { Fail "no patches under patches/ at '$PATCH_REF'" }

if (Test-Path $PATCH_DIR) {
    # Clear first: a series that SHRANK would otherwise leave orphans behind that
    # git am would still pick up and apply.
    Remove-Item (Join-Path $PATCH_DIR '*.patch') -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $PATCH_DIR | Out-Null
}
Copy-Item (Join-Path $srcDir.FullName 'patches\*.patch') $PATCH_DIR -Force
Stage ("patch series synced from '" + $PATCH_REF + "': " + $srcPatches.Count + " patches")

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
#
#    SKIPPED when the deps are already synced for this exact tag.
#
#    NOTE ON THE ORIGINAL JUSTIFICATION: this was added believing gclient sync was
#    what made three runs time out. It was NOT - those runs never reached this
#    step at all. They hung in the step-0 patch sync above, which used git and sat
#    there forever; the log contained only the "starting" marker and the slowness
#    was misattributed to gclient. Keeping the skip anyway, because re-syncing
#    deps for a pin that has not moved is genuinely wasted work, but it is an
#    optimisation, not the fix for #62.
#
#    Skipping is safe because the TAG PINS DEPS: a given Chromium tag has one
#    DEPS file, so if the checkout is already at $TAG and a sync for $TAG has
#    completed before, re-syncing can only reproduce the same tree. What is NOT
#    safe is trusting a sync that did not finish, so the marker is written only
#    AFTER gclient exits 0 - an interrupted or failed sync leaves no marker and
#    the next run does the full sync again.
#
#    Overridable with DXR_FORCE_SYNC=1 for the case where the tree is suspected
#    bad and you want the slow, thorough path back.
$SYNC_MARKER = 'C:\build\last_synced_tag.txt'
$syncedTag = ''
if (Test-Path $SYNC_MARKER) { $syncedTag = (Get-Content $SYNC_MARKER -Raw).Trim() }
$forceSync = ($env:DXR_FORCE_SYNC -eq '1')

if (-not $forceSync -and $syncedTag -eq $TAG) {
    Stage "gclient sync SKIPPED - deps already synced for $TAG (set DXR_FORCE_SYNC=1 to force)"
} else {
    if ($forceSync) { Stage 'gclient sync forced by DXR_FORCE_SYNC=1' }
    else { Stage ("gclient sync needed - marker='" + $syncedTag + "' target='" + $TAG + "'") }
    # Clear the marker first: if we die mid-sync the tree is in an unknown state
    # and the next run must NOT believe it is synced.
    Remove-Item $SYNC_MARKER -ErrorAction SilentlyContinue
    cmd /c "cd /d C:\cr && gclient sync -D --force --reset --nohooks >> $LOG 2>&1"
    if ($LASTEXITCODE -ne 0) { Fail 'gclient sync' }
    Stage 'gclient sync OK'
    cmd /c "cd /d C:\cr && gclient runhooks >> $LOG 2>&1"
    Stage 'runhooks done'
    Set-Content -Path $SYNC_MARKER -Value $TAG -Encoding ascii
}

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
