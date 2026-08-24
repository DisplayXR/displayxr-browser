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

# The VC++ runtime DLLs and the service/diagnostic binaries above were MISSING from this
# list until 2026-08, so every staged tree dropped them (caught by the win box diffing an
# installed 0.1.5 against a staged build: 79 files dropped, ~12 of them not build junk).
#
# EVIDENCE NOTE, because the reason matters if this list is ever trimmed again: the report
# said chrome.exe links the VC++ runtimes and a clean box might fail to launch. That
# specific mechanism does NOT hold — an import scan of all 14 shipped binaries finds no
# reference to msvcp140/vcruntime140/vccorlib140 (control: Kernel32.dll IS found the same
# way), consistent with an official build static-linking the CRT. They are shipped anyway
# because the asymmetry is stark: ~2 MB versus a browser that cannot start on a machine
# without the redistributable, and nobody here can test a clean Windows box. Do not remove
# them on the strength of the import scan alone — verify on a VM with no VC++ redist first.
#
# dbghelp.dll is the exception in the other direction: it IS a genuine DELAY-LOAD dependency
# of chrome.exe (dumpbin -dependents on an installed tree, win box). It would fall back to
# the System32 copy, but Chromium deliberately ships a newer one for crash symbolization, so
# it belongs here for a real reason rather than as insurance. dbgcore.dll is its companion.
#
# The others are feature-degradation rather than launch-blocking: notification_helper (native
# toasts), elevation_service + elevated_tracing_service, eventlog_provider.
#
# Both scans agree on the VC++ five, by different methods on different trees: an import scan
# here and dumpbin -dependents on an installed 0.1.5 there. chrome.exe's real imports are
# just chrome_elf.dll, KERNEL32.dll, ntdll.dll and VERSION.dll.
#
# Core run-set of an official static Chromium build. (A static build has far fewer DLLs than the
# component build; the vendored openxr_loader.dll ships alongside for the weave client.)
# chrome.exe is only a launcher stub even in a static build — the code is chrome.dll (~300-400MB).
for item in \
  chrome.exe chrome.dll chrome_wer.dll chrome_elf.dll \
  chrome_proxy.exe chrome_pwa_launcher.exe \
  chrome_100_percent.pak chrome_200_percent.pak resources.pak \
  icudtl.dat v8_context_snapshot.bin snapshot_blob.bin \
  vk_swiftshader.dll vk_swiftshader_icd.json vulkan-1.dll libEGL.dll libGLESv2.dll \
  d3dcompiler_47.dll dxcompiler.dll dxil.dll \
  openxr_loader.dll \
  msvcp140.dll msvcp140_atomic_wait.dll vcruntime140.dll vcruntime140_1.dll vccorlib140.dll \
  notification_helper.exe elevation_service.exe elevated_tracing_service.exe \
  eventlog_provider.dll dbgcore.dll dbghelp.dll ; do
  [ -e "$OUT/$item" ] && cp "$OUT/$item" "$STAGE/" || echo "[package]  (skip missing $item)"
done

# Locales + version-coded resource dir + external SxS manifest (chrome.exe fails
# "side-by-side configuration is incorrect" without <VER>.manifest next to it).
[ -d "$OUT/locales" ] && cp -r "$OUT/locales" "$STAGE/"
VER="$(cat "$CHROMIUM_SRC/chrome/VERSION" | awk -F= '/MAJOR/{a=$2}/MINOR/{b=$2}/BUILD/{c=$2}/PATCH/{d=$2}END{print a"."b"."c"."d}')"
# NOT a soft copy. Without <VER>.manifest next to chrome.exe the browser does not start
# at all -- Windows fails to build the activation context and reports "Dependent Assembly
# <VER> could not be found" to the SideBySide event log, before chrome writes a single log
# line. A `&& cp` that silently skips a missing manifest therefore produces a green build,
# a signed installer, and a browser that cannot launch. Hit for real on the .174 pin bump.
[ -f "$OUT/$VER.manifest" ] || {
  echo "[package] FATAL no $VER.manifest in $OUT — chrome.exe will fail to start."
  echo "[package]   present: $(ls "$OUT"/*.manifest 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
  echo "[package]   (a manifest for a DIFFERENT version means VER was derived from the wrong"
  echo "[package]    tag, or ninja left a stale one behind from a previous build.)"
  exit 1
}
cp "$OUT/$VER.manifest" "$STAGE/"
[ -d "$OUT/$VER" ] && cp -r "$OUT/$VER" "$STAGE/" || true

# Default landing page (displayxr-browser: default to the inline-3D samples).
# Chromium reads `initial_preferences` from NEXT TO chrome.exe to seed a NEW profile,
# so this ships as data rather than as a 55th source patch — nothing to rebase each
# milestone, and the user can still change their homepage afterwards. Seeds a new
# profile ONLY; an existing profile keeps whatever it already has.
if [ -f "$REPO/branding/initial_preferences" ]; then
  cp "$REPO/branding/initial_preferences" "$STAGE/initial_preferences"
  echo "[package] default landing page seeded (branding/initial_preferences)"
else
  echo "[package]  (skip missing branding/initial_preferences)"
fi

echo "[package] version $VER staged. Contents:"
ls -1 "$STAGE" | sed 's/^/  /'
echo "[package] done -> $STAGE"
