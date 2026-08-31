#!/usr/bin/env bash
# build.sh — apply the inline-3D patch series, brand, and build the lane's product.
#
#   1. git am the patches/ series onto the pinned tag (idempotent: skips if already applied)
#   2. brand.sh (product strings)
#   3. write out/$OUT_DIR/args.gn ($GN_ARGS_FILE) + gn gen
#   4. autoninja $NINJA_TARGET, in a retry loop (a self-hosted box may kill long builds;
#      autoninja is incremental so each relaunch resumes). First official static build is
#      multi-hour.
#
# TWO LANES, ONE SCRIPT. DXR_TARGET_OS=win (default) builds `chrome` with args.official.gn on
# the Windows box; DXR_TARGET_OS=android builds `chrome_public_apk` with args.android.gn on
# the EC2 Linux builder. Both read the pin from scripts/config.env and nowhere else.
#
# On success: $CHROMIUM_SRC/out/$OUT_DIR/chrome.exe (win) or
#             $CHROMIUM_SRC/out/$OUT_DIR/apks/$APK_NAME (android).
# Verify the weave per docs/rebase-runbook.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"
export PATH="$DEPOT_TOOLS:$PATH"

# On Linux, run gn/autoninja directly; on Windows they are batch shims that must go
# through `cmd //c` from git-bash. One indirection, defined once.
# Both take ONE command string so the two branches stay literally interchangeable — and
# `bash -c` word-splits it exactly the way `cmd //c` does, so neither branch has to quote
# differently from the other.
if [ "$DXR_TARGET_OS" = "android" ]; then
  run_tool() { bash -c "$*"; }
else
  run_tool() { cmd //c "$*"; }
fi

cd "$CHROMIUM_SRC"

# --- 1. apply patch series (skip cleanly if the tree already matches the fork) --------------
if git merge-base --is-ancestor "$CHROMIUM_TAG" HEAD 2>/dev/null && \
   [ -f third_party/displayxr/README.displayxr ]; then
  echo "[build] inline-3D patches appear already applied — skipping git am"
else
  echo "[build] resetting to $CHROMIUM_TAG and applying patches/*.patch"
  git checkout "$CHROMIUM_TAG"
  git checkout -B displayxr-inline-3d
  git am --3way --keep-non-patch "$REPO"/patches/*.patch
fi

# --- 2. brand -------------------------------------------------------------------------------
bash "$HERE/brand.sh"

# --- 3. gn gen ------------------------------------------------------------------------------
OUT="out/$OUT_DIR"
mkdir -p "$OUT"
cp "$REPO/scripts/$GN_ARGS_FILE" "$OUT/args.gn"
echo "[build] gn gen $OUT (args=$GN_ARGS_FILE)"
run_tool "gn gen $OUT"

# --- 4. autoninja retry loop ----------------------------------------------------------------
if [ "$DXR_TARGET_OS" != "android" ]; then
  # Windows only: a running chrome.exe locks the build outputs. There is nothing to kill on
  # the Linux builder (the APK is never run there — it is installed on the device).
  echo "[build] kill any running chrome (locks build outputs)"
  powershell -NoProfile -Command "Get-Process chrome,'DisplayXR Browser' -ErrorAction SilentlyContinue | Stop-Process -Force" || true
fi

max=400
for i in $(seq 1 $max); do
  echo "[build] === autoninja attempt $i ($NINJA_TARGET) ==="
  if run_tool "autoninja -C $OUT $NINJA_TARGET"; then
    if [ "$DXR_TARGET_OS" = "android" ]; then
      APK="$CHROMIUM_SRC/$OUT/apks/$APK_NAME"
      # A green autoninja that produced no APK is a lane bug, not a build success —
      # say so here rather than letting the upload step fail with "no such file".
      [ -f "$APK" ] || { echo "[build] ERROR — autoninja succeeded but no APK at $APK"; exit 1; }
      echo "[build] DONE — $APK"
      # NB: self-signed with Chromium's checked-in DEBUG key. A release keystore +
      # apksigner step is deferred (docs/android-port.md § Build lane).
    else
      echo "[build] DONE — $CHROMIUM_SRC/$OUT/chrome.exe"
    fi
    exit 0
  fi
  echo "[build] attempt $i failed (transient box-kill? retrying incrementally)"
  sleep 2
done
echo "[build] ERROR — exhausted $max attempts"
exit 1
