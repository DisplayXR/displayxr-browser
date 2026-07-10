#!/usr/bin/env bash
# package.sh — stage a runnable DisplayXR Browser tree from an official build.
#
# Collects the minimal run-set from out/$OUT_DIR into dist/DisplayXR-Browser/ (the tree the P2
# installer packs). Not a Chromium mini_installer — the preview installer (displayxr-browser-installer,
# P2) wraps this staged tree and chains the DisplayXR runtime + display plug-in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"

OUT="$CHROMIUM_SRC/out/$OUT_DIR"
STAGE="$REPO/dist/DisplayXR-Browser"
[ -f "$OUT/chrome.exe" ] || { echo "[package] no $OUT/chrome.exe — run build.sh first"; exit 1; }

echo "[package] staging -> $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# Core run-set of an official static Chromium build. (A static build has far fewer DLLs than the
# component build; the vendored openxr_loader.dll ships alongside for the weave client.)
for item in \
  chrome.exe chrome_proxy.exe chrome_pwa_launcher.exe \
  chrome_100_percent.pak chrome_200_percent.pak resources.pak \
  icudtl.dat v8_context_snapshot.bin snapshot_blob.bin \
  vk_swiftshader.dll vk_swiftshader_icd.json vulkan-1.dll libEGL.dll libGLESv2.dll \
  d3dcompiler_47.dll dxcompiler.dll dxil.dll \
  openxr_loader.dll ; do
  [ -e "$OUT/$item" ] && cp "$OUT/$item" "$STAGE/" || echo "[package]  (skip missing $item)"
done

# Locales + version-coded resource dir.
[ -d "$OUT/locales" ] && cp -r "$OUT/locales" "$STAGE/"
VER="$(cat "$CHROMIUM_SRC/chrome/VERSION" | awk -F= '/MAJOR/{a=$2}/MINOR/{b=$2}/BUILD/{c=$2}/PATCH/{d=$2}END{print a"."b"."c"."d}')"
[ -d "$OUT/$VER" ] && cp -r "$OUT/$VER" "$STAGE/" || true

echo "[package] version $VER staged. Contents:"
ls -1 "$STAGE" | sed 's/^/  /'
echo "[package] done -> $STAGE"
