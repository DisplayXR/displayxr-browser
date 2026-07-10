#!/usr/bin/env bash
# build.sh — apply the inline-3D patch series, brand, and build an official static chrome.exe.
#
#   1. git am the patches/ series onto the pinned tag (idempotent: skips if already applied)
#   2. brand.sh (product strings)
#   3. write out/$OUT_DIR/args.gn (official static) + gn gen
#   4. autoninja chrome, in a retry loop (a self-hosted box may kill long builds; autoninja is
#      incremental so each relaunch resumes). First official static build is multi-hour.
#
# On success: $CHROMIUM_SRC/out/$OUT_DIR/chrome.exe. Verify the weave per docs/rebase-runbook.md.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"
export PATH="$DEPOT_TOOLS:$PATH"

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
cp "$REPO/scripts/args.official.gn" "$OUT/args.gn"
echo "[build] gn gen $OUT"
cmd //c "gn gen $OUT"

# --- 4. autoninja retry loop ----------------------------------------------------------------
echo "[build] kill any running chrome (locks build outputs)"
powershell -NoProfile -Command "Get-Process chrome,'DisplayXR Browser' -ErrorAction SilentlyContinue | Stop-Process -Force" || true

max=400
for i in $(seq 1 $max); do
  echo "[build] === autoninja attempt $i ==="
  if cmd //c "autoninja -C $OUT chrome"; then
    echo "[build] DONE — $CHROMIUM_SRC/$OUT/chrome.exe"
    exit 0
  fi
  echo "[build] attempt $i failed (transient box-kill? retrying incrementally)"
  sleep 2
done
echo "[build] ERROR — exhausted $max attempts"
exit 1
