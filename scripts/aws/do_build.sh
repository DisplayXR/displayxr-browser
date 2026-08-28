#!/usr/bin/env bash
# do_build.sh - build chrome_public_apk ON the EC2 Linux builder, under the same marker
# protocol as do_rebase.sh. The Linux analogue of the Windows box's do_build.ps1 - except
# that one is NOT repo-tracked, which is exactly the drift this file exists to avoid.
#
# Runs as the `builder` user (build-box-android.yml steps down with `sudo -u builder`).
#
# IT DOES NOT REIMPLEMENT THE BUILD. It runs scripts/build.sh out of the repo copy
# do_rebase.sh downloaded, with DXR_TARGET_OS=android, so the box builds with the SAME
# script, the SAME args.android.gn and the SAME pin as a local build. Anything build-shaped
# belongs in scripts/build.sh; this file is only the marker/log/staging wrapper.
#
# MARKER CONTRACT (identical to do_rebase.sh and to the Windows lane):
#   $BUILD_DIR/$JOB.done    written LAST: "OK <apk> <bytes>" or "ERROR: <msg>"
#   $BUILD_DIR/$JOB.status  one "=== stage ===" line per milestone
#   $BUILD_DIR/$JOB.log     full build log (multi-GB-of-ninja-noise lives HERE, not stdout)
#
# STDOUT IS PRECIOUS. SSM's get-command-invocation truncates StandardOutputContent, so a
# build that streamed ninja to stdout would lose its own tail. Everything noisy goes to the
# log; stdout gets stage markers plus a bounded tail at the end.

# NOT `set -e`: every failure path must still write the .done marker.
set -uo pipefail

BUILD_DIR="${DXR_BUILD_ROOT:-/opt/build}"
JOB="${DXR_JOB:-androidbuild}"
export DXR_TARGET_OS=android
export DXR_BUILD_ROOT="$BUILD_DIR"
export CHROMIUM_SRC="${CHROMIUM_SRC:-$BUILD_DIR/cr/src}"
export DEPOT_TOOLS="${DEPOT_TOOLS:-$BUILD_DIR/depot_tools}"
export OUT_DIR="${OUT_DIR:-Android}"
export DEPOT_TOOLS_UPDATE=0
export GIT_TERMINAL_PROMPT=0

LOG="$BUILD_DIR/$JOB.log"
STATUS="$BUILD_DIR/$JOB.status"
DONE="$BUILD_DIR/$JOB.done"

mkdir -p "$BUILD_DIR"
rm -f "$DONE" "$LOG" "$STATUS"

stage() {
  local line="=== $* ==="
  echo "$line"
  printf '%s\n' "$line" >> "$STATUS"
  printf '%s\n' "$line" >> "$LOG"
}
tail_log() {
  if [ -f "$LOG" ]; then
    echo "--- $JOB.log (tail) ---"
    tail -n 40 "$LOG"
  fi
}
fail() {
  stage "ERROR: $*"
  tail_log
  printf 'ERROR: %s\n' "$*" > "$DONE"
  exit 1
}

stage "android build starting (job=$JOB src=$CHROMIUM_SRC out=$OUT_DIR)"

# The repo copy do_rebase.sh extracted. Refuse to guess: building from a stale extraction
# is how the box silently drifts from the ref CI thinks it is building.
REPO_PTR="$BUILD_DIR/repo_dir.txt"
[ -f "$REPO_PTR" ] || fail "no $REPO_PTR - run the rebase step first (it downloads the repo)"
SRC_DIR="$(tr -d ' \n\r' < "$REPO_PTR")"
[ -d "$SRC_DIR/scripts" ] || fail "repo pointer '$SRC_DIR' has no scripts/ - stale or bad extraction"
[ -f "$SRC_DIR/scripts/args.android.gn" ] || fail "no scripts/args.android.gn at '$SRC_DIR' - the ref predates the Android lane"
stage "building from repo copy $SRC_DIR"

# build.sh is bash and idempotent: it detects the already-applied series from do_rebase.sh
# and skips `git am`, then brands, gn gens with args.android.gn and autoninjas
# chrome_public_apk. Its own retry loop handles a box-killed ninja.
if ! bash "$SRC_DIR/scripts/build.sh" >> "$LOG" 2>&1; then
  fail "scripts/build.sh failed - see $LOG"
fi
stage "scripts/build.sh returned OK"

APK_NAME="${APK_NAME:-ChromePublic.apk}"
APK="$CHROMIUM_SRC/out/$OUT_DIR/apks/$APK_NAME"
[ -f "$APK" ] || fail "build reported success but there is no APK at $APK"

# Stage it at a PREDICTABLE, run-agnostic path so the workflow's upload step does not have
# to know Chromium's output layout. Copy, never move: a move would defeat autoninja's
# incremental rebuild on the next run.
STAGED="$BUILD_DIR/$JOB.apk"
cp -f "$APK" "$STAGED" || fail "staging the APK to $STAGED"
# `wc -c`, not `stat -c %s` (GNU-only; a BSD stat prints nothing and the size reads 0).
BYTES="$(wc -c < "$STAGED" | tr -d ' ')"
stage "APK staged: $STAGED ($(( BYTES / 1024 / 1024 )) MB)"
# Self-signed with Chromium's checked-in DEBUG key. Deliberate for the preview; a release
# keystore + apksigner step is deferred (docs/android-port.md, § Build lane).
stage "NOTE: debug-key self-signed (no release keystore yet)"

tail_log
printf 'OK %s %s\n' "$STAGED" "$BYTES" > "$DONE"
stage "ANDROID BUILD DONE"
