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
# TWO kinds of failure, and conflating them is how #132 cost two builds and a
# wrong diagnosis. Fail() means THE SERIES DID NOT APPLY - a real drift signal,
# and the caller reports it as CONFLICT. FailHarness() means WE could not get far
# enough to judge the series (bad ref, download, unzip, gclient, a command line
# we overflowed ourselves): the series is unjudged, so saying "conflict" about it
# is a lie that sends someone to rewrite patches that are fine.
function Fail($m){ Stage "ERROR: $m"; "ERROR: $m" | Out-File $DONE -Encoding ascii; exit 1 }
function FailHarness($m){ Stage "HARNESS: $m"; "HARNESS: $m" | Out-File $DONE -Encoding ascii; exit 1 }

# RunCmd() - `cmd /c` with a length tripwire. Use it for ANY command string whose
# length grows with the patch series. (The fixed-length `cmd /c` calls below cannot
# grow, so they call cmd directly.)
#
# #132: the `git am` call in step 4 used to inline all N patch paths into one
# `cmd /c` string. At 99 patches that string crossed cmd.exe's ceiling, cmd
# rejected the whole thing with "The command line is too long.", `git am` NEVER
# STARTED - and because the `>> $LOG 2>&1` redirect is part of the same rejected
# string, rebase.log received not one byte of am output. $LASTEXITCODE was 1, so
# the drift gate reported "patch series did not apply cleanly" for a series that
# applies perfectly. A gate that blames the series for its own overflow is worse
# than one that crashes, so: measure the string, and Fail with the number.
#
# Ceiling measured on the box class is 8156 chars for the string handed to cmd
# (the documented 8191 less the `cmd /c ` prefix and quoting); 8000 leaves slack.
$CMD_MAX = 8000
function RunCmd($c){
  if ($c.Length -gt $CMD_MAX) {
    FailHarness ("internal: cmd line is " + $c.Length + " chars, over the $CMD_MAX cap " +
          "(cmd.exe ceiling ~8156) - this is a HARNESS fault, not patch drift (#132)")
  }
  cmd /c $c
}

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

# codeload wants refs/heads/<branch> for a branch, but a bare SHA for a commit,
# and it 404s on the wrong form rather than redirecting. The old test only
# recognised a FULL 40-char SHA, so an ABBREVIATED one ('634581a') was sent as
# refs/heads/634581a, 404d, and - because the download used Fail() - was reported
# to CI as a patch CONFLICT. Nobody can guess the ref form from that.
#
# So try both forms rather than predicting one. Order by what the ref looks like
# (hex 7-40 chars is probably a SHA) and fall through on failure; a branch whose
# name happens to be hex still resolves, just on the second attempt.
$ProgressPreference = 'SilentlyContinue'   # progress UI is slow and useless here
if ($PATCH_REF -match '^[0-9a-fA-F]{7,40}$') { $forms = @($PATCH_REF, "refs/heads/$PATCH_REF") }
else { $forms = @("refs/heads/$PATCH_REF", $PATCH_REF) }
$dlErrors = @()
foreach ($refPath in $forms) {
    $URL = "https://codeload.github.com/DisplayXR/displayxr-browser/zip/$refPath"
    Stage "downloading patch series from $URL"
    try {
        Invoke-WebRequest -Uri $URL -OutFile $ZIP -UseBasicParsing -TimeoutSec 300
        break
    } catch {
        $dlErrors += ($refPath + ' -> ' + $_.Exception.Message)
        Remove-Item $ZIP -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $ZIP)) {
    FailHarness ("could not download the patch series for ref '" + $PATCH_REF +
                 "' in any form (" + ($dlErrors -join '; ') +
                 "). The series was never judged - this is NOT a patch conflict.")
}
Stage ("downloaded " + [math]::Round((Get-Item $ZIP).Length/1KB) + " KB")

try { Expand-Archive -Path $ZIP -DestinationPath $EXT -Force }
catch { FailHarness ("expand failed: " + $_.Exception.Message) }

$srcDir = Get-ChildItem $EXT -Directory | Select-Object -First 1
if (-not $srcDir) { FailHarness "zip contained no top-level directory" }
$srcPatches = @(Get-ChildItem (Join-Path $srcDir.FullName 'patches\*.patch') -ErrorAction SilentlyContinue)
if ($srcPatches.Count -eq 0) { FailHarness "no patches under patches/ at '$PATCH_REF'" }

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
if ($LASTEXITCODE -ne 0) { FailHarness "checkout $TAG" }
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
    if ($LASTEXITCODE -ne 0) { FailHarness 'gclient sync' }
    Stage 'gclient sync OK'
    cmd /c "cd /d C:\cr && gclient runhooks >> $LOG 2>&1"
    Stage 'runhooks done'
    Set-Content -Path $SYNC_MARKER -Value $TAG -Encoding ascii
}

# 4. Re-apply the inline-3D patch series. THE DRIFT GATE: if `git am` fails the series
#    needs a manual rebase (#36) and we must NOT proceed to a build.
$patches = Get-ChildItem 'C:\build\patches\*.patch' | Sort-Object Name
if (-not $patches) { FailHarness 'no patches found at C:\build\patches' }
Stage ("applying " + $patches.Count + " patches")

# Concatenate the series into ONE mbox and pass ONE path (#132).
#
# `git format-patch` output IS mbox: every patch file opens with
# "From <sha> Mon Sep 17 00:00:00 2001", so a concatenation in series order is a
# valid mbox that `git am` consumes exactly as it consumes N separate files. The
# point is not a bigger command-line budget - it is a command line whose length is
# CONSTANT, and therefore immune to the series growing. The old shape passed
# ~82 chars of command line per patch and died the moment the series reached 99.
#
# The copy must be byte-level. Get-Content/Set-Content would round-trip through PS
# 5.1's encoding and line-ending handling, which corrupts the base85 payload of the
# binary hunks (0001 carries third_party/displayxr/lib/openxr_loader.lib) and every
# patch's context whitespace with it. [IO.File] streams the raw bytes untouched.
$MBOX = 'C:\build\series.mbox'
Remove-Item $MBOX -ErrorAction SilentlyContinue
$fs = [System.IO.File]::Create($MBOX)
try {
  foreach ($p in $patches) {
    $b = [System.IO.File]::ReadAllBytes($p.FullName)
    $fs.Write($b, 0, $b.Length)
  }
} finally { $fs.Close() }
Stage ("series.mbox built - " + [math]::Round((Get-Item $MBOX).Length/1KB) + " KB from " + $patches.Count + " patches")

RunCmd "cd /d C:\cr\src && git am --3way --keep-non-patch $MBOX >> $LOG 2>&1"
if ($LASTEXITCODE -ne 0) {
  # Capture the failing patch before aborting, so the CI job can name it.
  $failing = (cmd /c "cd /d C:\cr\src && git am --show-current-patch=raw 2>nul | findstr /b Subject")
  cmd /c "cd /d C:\cr\src && git am --abort >> $LOG 2>&1"
  if ($failing) {
    Stage "FAILING PATCH: $failing"
    Fail "patch series did not apply cleanly on $TAG (rebase needed - #36)"
  }
  # Nothing to show => there is no am in progress => `git am` never started, so
  # NOTHING has been learned about the series. Do NOT fall through to the drift
  # message: #132 lost a full diagnosis cycle to this branch blaming patches/ for
  # a harness bug. The tell in the log is `git am --abort` answering "Resolve
  # operation not in progress, we are not resuming" with no "Applying:" line
  # above it. Say what actually happened.
  FailHarness ("git am NEVER STARTED - HARNESS fault, not a patch conflict. The series was " +
        "NOT tested and is not implicated. Debug do_rebase.ps1, not patches/ (#132)")
}
Stage 'patch series applied cleanly'

# 5. Apply DisplayXR product branding.
#
#    This is what scripts/brand.sh does for a LOCAL build, and the box never did
#    it: do_build.ps1 (which is not repo-tracked) does not call brand.sh, so every
#    artifact the lane has ever produced identified itself as
#
#        ProductName = Chromium
#        CompanyName = The Chromium Authors
#
#    which misattributes the product and ships under a name that is not ours.
#    Caught on the first green build, before signing.
#
#    It belongs HERE rather than in do_build.ps1 because it is a source-tree
#    modification exactly like the patch series - and putting it in the tracked
#    script keeps it from drifting the way the untracked one did. It must come
#    after the checkout/reset above (which would wipe it) and is independent of
#    the patches, which never touch this file.
$brandSrc = Join-Path $srcDir.FullName 'branding/BRANDING'
$brandDst = 'C:\cr\src\chrome\app\theme\chromium\BRANDING'
if (-not (Test-Path $brandSrc)) { FailHarness "no branding/BRANDING in the downloaded series" }
Copy-Item $brandSrc $brandDst -Force
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $brandDst)) { FailHarness 'branding copy failed' }
$prod = (Select-String -Path $brandDst -Pattern '^PRODUCT_FULLNAME=' | Select-Object -First 1).Line
Stage ("branding applied - " + $prod)

$desc = (cmd /c "cd /d C:\cr\src && git describe --tags").Trim()
Stage "HEAD = $desc"
"OK $TAG $desc" | Out-File $DONE -Encoding ascii
Stage 'REBASE DONE'
