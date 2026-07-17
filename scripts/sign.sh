#!/usr/bin/env bash
# sign.sh — EV-sign the DisplayXR Browser's first-party binaries via the signing provider.
#
# The browser is NOT a registered component in the provider's build-signed-release.yml, so it uses
# the folder-sign path (release-signing.md §2): zip the unsigned files, hand them to the provider's
# `sign-artifact` workflow, get them back signed. Signing NEVER gates publishing — if the provider is
# unreachable this warns and exits non-fatally so the caller can ship unsigned (with a warning).
#
# FIRST-PARTY ONLY. We sign the binaries we build/ship-as-ours (chrome.exe + chrome.dll + the ELF/WER/
# proxy/pwa launcher stubs). The bundled third-party redistributables (vulkan-1.dll, vk_swiftshader*,
# d3dcompiler_47.dll, dxcompiler.dll, dxil.dll, openxr_loader.dll) keep their ORIGINAL signatures —
# re-signing Microsoft/Khronos/LunarG DLLs with the Leia cert would overwrite a stronger provenance
# with a weaker one. This mirrors how Chrome's own official build signs Google's binaries only.
#
# Provider is named out-of-band by $DXR_SIGN_REPO (e.g. from ../displayxr-runtime/.env.local).
# Usage: scripts/sign.sh <dir-of-binaries-to-sign>   (default: dist/DisplayXR-Browser)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"

SRC_DIR="${1:-$REPO/dist/DisplayXR-Browser}"
LOCAL_HOOK="C:/displayxr-signing/sign-hook.sh"

# First-party PE files we sign (must exist in SRC_DIR; missing ones are skipped, not an error).
FIRST_PARTY=(
  chrome.exe chrome.dll chrome_elf.dll chrome_wer.dll
  chrome_proxy.exe chrome_pwa_launcher.exe
)
# Files we must confirm came back Authenticode-Valid before declaring success.
VERIFY=( chrome.exe chrome.dll )

if [ ! -d "$SRC_DIR" ]; then echo "[sign] no dir $SRC_DIR"; exit 1; fi

# Collect the first-party set into a flat temp dir so ONLY those files are handed to the signer.
SIGN_DIR="$(mktemp -d)"
cleanup_signdir() { rm -rf "$SIGN_DIR"; }
trap cleanup_signdir EXIT
present=()
for f in "${FIRST_PARTY[@]}"; do
  if [ -f "$SRC_DIR/$f" ]; then cp "$SRC_DIR/$f" "$SIGN_DIR/"; present+=("$f"); fi
done
if [ ${#present[@]} -eq 0 ]; then
  echo "[sign] WARN no first-party binaries found in $SRC_DIR — nothing to sign"; exit 0
fi
echo "[sign] first-party set (${#present[@]}): ${present[*]}"

# copy signed files from SIGN_DIR back over SRC_DIR
copyback() { for f in "${present[@]}"; do cp -f "$SIGN_DIR/$f" "$SRC_DIR/$f"; done; }
verify() {
  for f in "${VERIFY[@]}"; do
    [ -f "$SRC_DIR/$f" ] || continue
    local st
    st="$(powershell -NoProfile -Command "(Get-AuthenticodeSignature '$(cygpath -w "$SRC_DIR/$f" 2>/dev/null || echo "$SRC_DIR/$f")').Status" 2>/dev/null | tr -d '\r')"
    echo "[sign]   verify $f = $st"
    [ "$st" = "Valid" ] || { echo "[sign] ERROR $f not Valid after signing"; return 1; }
  done
}

# 1) Local fallback: a box that holds the cert exposes sign-hook.sh (release-signing.md §fallback).
if [ -f "$LOCAL_HOOK" ]; then
  echo "[sign] local signer present -> $LOCAL_HOOK"
  if bash "$LOCAL_HOOK" "$SIGN_DIR"; then
    copyback; verify && { echo "[sign] signed locally — first-party binaries Valid"; exit 0; }
    echo "[sign] local sign verify FAILED"; exit 1
  fi
  echo "[sign] local hook failed — falling through to remote provider"
fi

# 2) Remote provider (the capability gate from release-signing.md).
SIGN_REPO="${DXR_SIGN_REPO:-}"
if [ -z "$SIGN_REPO" ] || ! gh workflow view sign-artifact -R "$SIGN_REPO" >/dev/null 2>&1; then
  echo "[sign] WARN provider unreachable (DXR_SIGN_REPO='${SIGN_REPO:-unset}') — shipping UNSIGNED inner binaries"
  exit 0
fi
echo "[sign] provider=$SIGN_REPO — folder-sign via sign-artifact"

TAG="browser-sign-$(cat "$CHROMIUM_SRC/chrome/VERSION" 2>/dev/null | awk -F= '/BUILD/{b=$2}/PATCH/{p=$2}END{print b"."p}')-$$"
ZIP="$(mktemp -d)/unsigned.zip"
( cd "$SIGN_DIR" && powershell -NoProfile -Command "Compress-Archive -Path * -DestinationPath '$(cygpath -w "$ZIP")' -Force" )

echo "[sign] uploading unsigned.zip as prerelease $TAG on $SIGN_REPO"
gh release create "$TAG" -R "$SIGN_REPO" --prerelease --title "$TAG" --notes "DisplayXR Browser folder-sign" "$ZIP#unsigned.zip"
gh workflow run sign-artifact -R "$SIGN_REPO" -f release_tag="$TAG"

echo "[sign] waiting for sign-artifact to finish…"
gh run watch -R "$SIGN_REPO" "$(gh run list -R "$SIGN_REPO" --workflow sign-artifact --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status || {
  echo "[sign] WARN sign-artifact run failed — shipping UNSIGNED inner binaries"; exit 0; }

OUTDIR="$(mktemp -d)"
gh run download -R "$SIGN_REPO" --name signed --dir "$OUTDIR"
powershell -NoProfile -Command "Expand-Archive -Path '$(cygpath -w "$OUTDIR/signed.zip")' -DestinationPath '$(cygpath -w "$SIGN_DIR")' -Force"
gh release delete "$TAG" -R "$SIGN_REPO" --yes --cleanup-tag || true

copyback
echo "[sign] verifying Authenticode chain"
verify || exit 1
echo "[sign] done — first-party binaries signed + Valid"
