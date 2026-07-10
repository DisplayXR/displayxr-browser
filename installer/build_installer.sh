#!/usr/bin/env bash
# build_installer.sh — stage the browser + compile the signed preview installer.
#
#   scripts/package.sh   → dist/DisplayXR-Browser/   (the runnable tree)
#   makensis             → DisplayXR-Browser-Preview-Setup-<ver>.<build>.exe
#
# Env:
#   BUILD_NUM       installer build number (default 0)
#   RUNTIME_SETUP   abs path to a DisplayXRSetup.exe to chain (optional; else the browser
#                   just requires an already-installed runtime)
#   SIGN_CMD        runner-local signer (optional; enables Authenticode + signed uninstaller)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$REPO/scripts/config.env"

VER="$(cat "$CHROMIUM_SRC/chrome/VERSION" | awk -F= '/MAJOR/{a=$2}/MINOR/{b=$2}/BUILD/{c=$2}/PATCH/{d=$2}END{print a"."b"."c"."d}')"
STAGE="$REPO/dist/DisplayXR-Browser"
OUT="$REPO/dist"; mkdir -p "$OUT"

echo "[installer] staging browser tree (version $VER)"
bash "$REPO/scripts/package.sh"

# to-Windows path helper (makensis wants native paths)
w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

ARGS=( -DVERSION="$VER" -DBUILD_NUM="${BUILD_NUM:-0}"
       -DSTAGE_DIR="$(w "$STAGE")" -DSOURCE_DIR="$(w "$REPO")" -DOUTPUT_DIR="$(w "$OUT")" )
[ -f "$REPO/LICENSE" ] && ARGS+=( -DLICENSE_FILE="$(w "$REPO/LICENSE")" )
[ -n "${RUNTIME_SETUP:-}" ] && ARGS+=( -DRUNTIME_SETUP="$(w "$RUNTIME_SETUP")" )
[ -n "${SIGN_CMD:-}" ]      && ARGS+=( -DSIGN_CMD="$SIGN_CMD" )

echo "[installer] makensis ${ARGS[*]}"
makensis "${ARGS[@]}" "$(w "$HERE/DisplayXRBrowserInstaller.nsi")"

echo "[installer] done -> $OUT/DisplayXR-Browser-Preview-Setup-$VER.${BUILD_NUM:-0}.exe"
