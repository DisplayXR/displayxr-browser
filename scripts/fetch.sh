#!/usr/bin/env bash
# fetch.sh — provision a pristine Chromium checkout pinned to $CHROMIUM_TAG.
#
# Assumes depot_tools is installed at $DEPOT_TOOLS and on PATH (autoninja/gn/gclient/git).
# Idempotent-ish: if $CHROMIUM_SRC already exists it re-syncs to the pinned tag instead of
# re-fetching from scratch. First fetch of full Chromium is tens of GB + long.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"

export PATH="$DEPOT_TOOLS:$PATH"
CHROMIUM_ROOT="$(dirname "$CHROMIUM_SRC")"   # the dir that will hold the gclient .gclient + src/

echo "[fetch] pin=$CHROMIUM_TAG src=$CHROMIUM_SRC"

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
