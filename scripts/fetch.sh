#!/usr/bin/env bash
# fetch.sh — provision a pristine Chromium checkout pinned to $CHROMIUM_TAG.
#
# Assumes depot_tools is installed at $DEPOT_TOOLS and on PATH (autoninja/gn/gclient/git).
# Idempotent-ish: if $CHROMIUM_SRC already exists it re-syncs to the pinned tag instead of
# re-fetching from scratch. First fetch of full Chromium is tens of GB + long.
#
# TWO LANES, ONE PIN. DXR_TARGET_OS=android (see config.env) switches this to the EC2 Linux
# builder's Android checkout: `.gclient` gains target_os=['android'] and the checkout runs
# build/install-build-deps.sh --android. The tag still comes from scripts/config.env and
# NOWHERE else.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"

export PATH="$DEPOT_TOOLS:$PATH"
CHROMIUM_ROOT="$(dirname "$CHROMIUM_SRC")"   # the dir that will hold the gclient .gclient + src/

echo "[fetch] os=$DXR_TARGET_OS pin=$CHROMIUM_TAG src=$CHROMIUM_SRC"

if [ "$DXR_TARGET_OS" = "android" ]; then
  # ── Android / Linux ───────────────────────────────────────────────────────────────
  # No `cmd //c` here: this runs on real Linux (the git-bash indirection the Windows
  # branch needs would fail outright).
  if [ ! -d "$CHROMIUM_SRC/.git" ]; then
    echo "[fetch] no checkout — running 'fetch chromium' (this is large + slow)"
    mkdir -p "$CHROMIUM_ROOT"
    ( cd "$CHROMIUM_ROOT" && fetch --nohooks chromium )
  fi

  # target_os=['android'] must be in .gclient BEFORE the sync, or the sync pulls no
  # Android toolchain/SDK/NDK and `gn gen` fails much later with an opaque error.
  # Appending is idempotent — check first.
  GCLIENT_FILE="$CHROMIUM_ROOT/.gclient"
  if [ -f "$GCLIENT_FILE" ] && ! grep -q "target_os" "$GCLIENT_FILE"; then
    echo "[fetch] adding target_os = ['android'] to $GCLIENT_FILE"
    printf "\ntarget_os = ['android']\n" >> "$GCLIENT_FILE"
  else
    echo "[fetch] .gclient already carries a target_os line — leaving it alone"
  fi

  echo "[fetch] checking out tag $CHROMIUM_TAG"
  ( cd "$CHROMIUM_SRC" \
      && git fetch --tags origin \
      && git checkout "$CHROMIUM_TAG" )

  echo "[fetch] gclient sync to the pinned tag"
  ( cd "$CHROMIUM_SRC" && gclient sync -D --force --reset )

  # Android build deps (SDK/NDK host packages, java, 32-bit libs). Needs root; the box
  # runs the build as `builder`, so this is the one step that wants sudo. Skippable once
  # the box has been provisioned — it is slow and touches apt.
  if [ "${DXR_SKIP_BUILD_DEPS:-0}" != "1" ]; then
    echo "[fetch] build/install-build-deps.sh --android (sudo; set DXR_SKIP_BUILD_DEPS=1 to skip)"
    ( cd "$CHROMIUM_SRC" && sudo ./build/install-build-deps.sh --android )
  else
    echo "[fetch] install-build-deps SKIPPED (DXR_SKIP_BUILD_DEPS=1)"
  fi

  echo "[fetch] running hooks"
  ( cd "$CHROMIUM_SRC" && gclient runhooks )

  echo "[fetch] done — pristine Chromium at $CHROMIUM_TAG (android). Next: scripts/build.sh"
  exit 0
fi

# ── Windows (unchanged) ─────────────────────────────────────────────────────────────
if [ ! -d "$CHROMIUM_SRC/.git" ]; then
  echo "[fetch] no checkout — running 'fetch chromium' (this is large + slow)"
  mkdir -p "$CHROMIUM_ROOT"
  ( cd "$CHROMIUM_ROOT" && cmd //c "fetch --nohooks chromium" )
fi

echo "[fetch] checking out tag $CHROMIUM_TAG"
( cd "$CHROMIUM_SRC" \
    && git fetch --tags origin \
    && git checkout "$CHROMIUM_TAG" )

echo "[fetch] gclient sync to the pinned tag"
( cd "$CHROMIUM_SRC" && cmd //c "gclient sync -D --force --reset" )

echo "[fetch] running hooks"
( cd "$CHROMIUM_SRC" && cmd //c "gclient runhooks" )

echo "[fetch] done — pristine Chromium at $CHROMIUM_TAG. Next: scripts/build.sh"
