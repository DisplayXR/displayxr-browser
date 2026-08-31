#!/usr/bin/env bash
# do_rebase.sh - the LINUX TWIN of do_rebase.ps1. Rebase the Android builder's Chromium
# checkout onto a target tag and re-apply the inline-3D patch series.
#
# Runs ON the EC2 Linux builder as the `builder` user (SSM RunCommand's agent is root, so
# .github/workflows/build-box-android.yml steps DOWN with `sudo -u builder` — the Linux
# analogue of the Windows lane's `crbuild` scheduled task, which had to step UP).
#
# THE REPO IS THE SOURCE OF TRUTH. Exactly as on Windows, the patch series is PULLED from
# this repo at $DXR_PATCH_REF, not pushed to the box: a codeload zip over plain HTTPS, no
# git, no credential helper, no interactive prompt. See the "NO GIT HERE" note below — that
# rule was paid for on the Windows box and applies verbatim here.
#
# TARGET TAG: $DXR_TARGET_TAG. Falls back to the pin in scripts/config.env of the ref we
# just downloaded, so the tag can never come from a stale copy on the box.
#
# MARKER CONTRACT (identical to the Windows lane, which the CI side depends on):
#   $BUILD_DIR/$JOB.done    written LAST: "OK <tag> <describe>" clean, or "ERROR: <msg>"
#   $BUILD_DIR/$JOB.status  one "=== stage ===" line per milestone
#   $BUILD_DIR/$JOB.log     full log
# The .done marker is DELETED UP FRONT so a stale marker from a previous run can never be
# read as this run's verdict.
#
# A `git am` failure is the drift gate: abort and STOP. Do NOT proceed to a build - the
# series needs a manual rebase and a human eyeball.

# NOT `set -e`: every failure path must still write the .done marker, or the CI side waits
# out its whole timeout on a job that died in one second.
set -uo pipefail

BUILD_DIR="${DXR_BUILD_ROOT:-/opt/build}"
JOB="${DXR_JOB:-rebase}"
CHROMIUM_SRC="${CHROMIUM_SRC:-$BUILD_DIR/cr/src}"
CHROMIUM_ROOT="$(dirname "$CHROMIUM_SRC")"
DEPOT_TOOLS="${DEPOT_TOOLS:-$BUILD_DIR/depot_tools}"
PATCH_REF="${DXR_PATCH_REF:-main}"
REPO_SLUG="${DXR_REPO_SLUG:-DisplayXR/displayxr-browser}"

export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
# gclient/git must never stop for a prompt under a non-interactive SSM session.
export GIT_TERMINAL_PROMPT=0

LOG="$BUILD_DIR/$JOB.log"
STATUS="$BUILD_DIR/$JOB.status"
DONE="$BUILD_DIR/$JOB.done"

mkdir -p "$BUILD_DIR"
rm -f "$DONE" "$LOG" "$STATUS"

# One encoding, one format. The Windows twin had to fight Tee-Object's UTF-16LE-vs-ANSI
# mixture; the Linux analogue of that trap is colourised `tee` output, so we do not use
# tee at all - stages go to stdout AND the plain-text status/log files.
stage() {
  local line="=== $* ==="
  echo "$line"
  printf '%s\n' "$line" >> "$STATUS"
  printf '%s\n' "$line" >> "$LOG"
}
fail() {
  stage "ERROR: $*"
  printf 'ERROR: %s\n' "$*" > "$DONE"
  exit 1
}
# Run a command with all its noise going to the log, not to SSM's capped stdout.
logged() { "$@" >> "$LOG" 2>&1; }

stage "rebase starting (job=$JOB ref=$PATCH_REF src=$CHROMIUM_SRC)"

# ── 0. Sync the canonical patch series from the repo ──────────────────────────────────
#
# NO GIT HERE. The Windows twin's first version used `git clone`/`git fetch` and it HUNG:
# three runs burned their whole budget with nothing in the log but the "starting" marker,
# because anything git decides to prompt for blocks forever with no console. A patch series
# is just files - fetch them over plain HTTPS as a zip, with an explicit timeout and a hard
# failure instead of an infinite wait.
#
# Done BEFORE the tag checkout and gclient sync so a bad ref fails in seconds rather than
# after tens of minutes of syncing.
ZIP="$BUILD_DIR/patchsrc.zip"
EXT="$BUILD_DIR/patchsrc"
PATCH_DIR="$BUILD_DIR/patches"
rm -f "$ZIP"
rm -rf "$EXT"

# codeload wants refs/heads/<branch> for a branch, but a bare SHA for a commit.
if printf '%s' "$PATCH_REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  REF_PATH="$PATCH_REF"
else
  REF_PATH="refs/heads/$PATCH_REF"
fi
URL="https://codeload.github.com/$REPO_SLUG/zip/$REF_PATH"
stage "downloading patch series from $URL"
if ! curl -fsSL --max-time 300 -o "$ZIP" "$URL" >> "$LOG" 2>&1; then
  fail "download failed for ref '$PATCH_REF'"
fi
[ -s "$ZIP" ] || fail "no zip downloaded for ref '$PATCH_REF'"
# `wc -c`, not `stat -c %s`: -c is GNU-only and silently prints nothing on a BSD/macOS
# stat, so the size line would quietly read "0 KB" while the download was fine.
stage "downloaded $(( $(wc -c < "$ZIP") / 1024 )) KB"

mkdir -p "$EXT"
logged unzip -q -o "$ZIP" -d "$EXT" || fail "unzip failed"

SRC_DIR="$(find "$EXT" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$SRC_DIR" ] || fail "zip contained no top-level directory"
# Record where the repo landed so do_build.sh runs THIS ref's scripts/build.sh + args
# +patches, rather than re-deriving the path (or, worse, some older extraction).
printf '%s\n' "$SRC_DIR" > "$BUILD_DIR/repo_dir.txt"

SRC_PATCH_COUNT="$(find "$SRC_DIR/patches" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')"
[ "$SRC_PATCH_COUNT" -gt 0 ] || fail "no patches under patches/ at '$PATCH_REF'"

# Clear first: a series that SHRANK would otherwise leave orphans behind that git am
# would still pick up and apply.
mkdir -p "$PATCH_DIR"
rm -f "$PATCH_DIR"/*.patch
cp "$SRC_DIR"/patches/*.patch "$PATCH_DIR"/ || fail "copying patches into $PATCH_DIR"
stage "patch series synced from '$PATCH_REF': $SRC_PATCH_COUNT patches"

# THE PIN COMES FROM config.env AND NOWHERE ELSE. $DXR_TARGET_TAG (injected by CI) wins
# only because CI reads it out of that same file; with nothing injected we read the pin
# straight out of the ref we just downloaded rather than trusting anything on the box.
TAG="${DXR_TARGET_TAG:-}"
if [ -z "$TAG" ]; then
  # shellcheck source=/dev/null
  TAG="$( set +u; source "$SRC_DIR/scripts/config.env" >/dev/null 2>&1; printf '%s' "$CHROMIUM_TAG" )"
fi
[ -n "$TAG" ] || fail "no target tag: DXR_TARGET_TAG unset and no CHROMIUM_TAG in the downloaded config.env"
stage "target tag = $TAG"

# ── 1. Discard the working tree ───────────────────────────────────────────────────────
# The patch series in patches/ is canonical, so dirty files are disposable.
[ -d "$CHROMIUM_SRC/.git" ] || fail "no Chromium checkout at $CHROMIUM_SRC (run scripts/fetch.sh on the box first)"
logged git -C "$CHROMIUM_SRC" checkout -- .
logged git -C "$CHROMIUM_SRC" reset --hard
stage "working tree reset"

# ── 2. Fetch + check out the target tag ───────────────────────────────────────────────
if ! logged git -C "$CHROMIUM_SRC" fetch --tags --depth=1 origin tag "$TAG"; then
  logged git -C "$CHROMIUM_SRC" fetch --tags origin
fi
logged git -C "$CHROMIUM_SRC" checkout -f "$TAG" || fail "checkout $TAG"
stage "checked out $TAG"

# ── 3. gclient sync to match the tag ──────────────────────────────────────────────────
# SKIPPED when the deps are already synced for this exact tag. Safe because the TAG PINS
# DEPS: one Chromium tag has one DEPS file. What is NOT safe is trusting a sync that did
# not finish, so the marker is written only AFTER gclient exits 0 - an interrupted sync
# leaves no marker and the next run does the full sync again.
# DXR_FORCE_SYNC=1 forces the slow, thorough path back.
SYNC_MARKER="$BUILD_DIR/last_synced_tag.txt"
SYNCED_TAG=""
[ -f "$SYNC_MARKER" ] && SYNCED_TAG="$(tr -d ' \n\r' < "$SYNC_MARKER")"

if [ "${DXR_FORCE_SYNC:-0}" != "1" ] && [ "$SYNCED_TAG" = "$TAG" ]; then
  stage "gclient sync SKIPPED - deps already synced for $TAG (set DXR_FORCE_SYNC=1 to force)"
else
  stage "gclient sync needed - marker='$SYNCED_TAG' target='$TAG'"
  rm -f "$SYNC_MARKER"
  ( cd "$CHROMIUM_ROOT" && gclient sync -D --force --reset --nohooks ) >> "$LOG" 2>&1 \
    || fail "gclient sync"
  stage "gclient sync OK"
  ( cd "$CHROMIUM_ROOT" && gclient runhooks ) >> "$LOG" 2>&1
  stage "runhooks done"
  printf '%s\n' "$TAG" > "$SYNC_MARKER"
fi

# ── 4. Re-apply the inline-3D patch series. THE DRIFT GATE ────────────────────────────
# Concatenate the series into ONE mbox and pass ONE path. `git format-patch` output IS
# mbox, so a concatenation in series order is a valid mbox that `git am` consumes exactly
# as it consumes N separate files. The point is a command line whose length is CONSTANT
# and therefore immune to the series growing - the bug that broke the Windows lane at 99
# patches. `cat` is byte-level, which the binary hunks in patch 0001 require.
MBOX="$BUILD_DIR/series.mbox"
rm -f "$MBOX"
# shellcheck disable=SC2012
ls "$PATCH_DIR"/*.patch | sort | while read -r p; do cat "$p" >> "$MBOX"; done
[ -s "$MBOX" ] || fail "series.mbox is empty"
stage "series.mbox built - $(( $(wc -c < "$MBOX") / 1024 )) KB from $SRC_PATCH_COUNT patches"

if ! ( cd "$CHROMIUM_SRC" && git am --3way --keep-non-patch "$MBOX" ) >> "$LOG" 2>&1; then
  # Capture the failing patch before aborting, so the CI job can name it.
  FAILING="$( cd "$CHROMIUM_SRC" && git am --show-current-patch=raw 2>/dev/null | grep '^Subject' | head -1 )"
  logged git -C "$CHROMIUM_SRC" am --abort
  if [ -n "$FAILING" ]; then
    stage "FAILING PATCH: $FAILING"
    fail "patch series did not apply cleanly on $TAG (rebase needed)"
  fi
  # Nothing to show => there is no am in progress => `git am` never started, so NOTHING
  # has been learned about the series. Do NOT fall through to the drift message: on the
  # Windows lane that branch cost a full diagnosis cycle by blaming patches/ for a harness
  # bug. Say what actually happened.
  fail "git am NEVER STARTED - HARNESS fault, not a patch conflict. The series was NOT tested and is not implicated. Debug do_rebase.sh, not patches/"
fi
stage "patch series applied cleanly"

# ── 5. Apply DisplayXR product branding ───────────────────────────────────────────────
# Same reasoning as the Windows twin: this is a source-tree modification exactly like the
# patch series, it must come after the checkout/reset (which would wipe it), and keeping it
# in the tracked script is what stops it drifting. Without it the APK identifies itself as
# "Chromium" / "The Chromium Authors".
BRAND_SRC="$SRC_DIR/branding/BRANDING"
BRAND_DST="$CHROMIUM_SRC/chrome/app/theme/chromium/BRANDING"
[ -f "$BRAND_SRC" ] || fail "no branding/BRANDING in the downloaded series"
cp "$BRAND_SRC" "$BRAND_DST" || fail "branding copy failed"
stage "branding applied - $(grep -m1 '^PRODUCT_FULLNAME=' "$BRAND_DST")"

DESC="$( cd "$CHROMIUM_SRC" && git describe --tags 2>/dev/null | tr -d '\n' )"
stage "HEAD = $DESC"
printf 'OK %s %s\n' "$TAG" "$DESC" > "$DONE"
stage "REBASE DONE"
