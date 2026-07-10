#!/usr/bin/env bash
# sign.sh — EV-sign the DisplayXR Browser binaries via the signing provider.
#
# The browser is NOT a registered component in the provider's build-signed-release.yml, so it uses
# the folder-sign path (release-signing.md §2): zip the unsigned files, hand them to the provider's
# `sign-artifact` workflow, get them back signed. Signing NEVER gates publishing — if the provider is
# unreachable this warns and exits non-fatally so the caller can ship unsigned (with a warning).
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

if [ ! -d "$SRC_DIR" ]; then echo "[sign] no dir $SRC_DIR"; exit 1; fi

# 1) Local fallback: a box that holds the cert exposes sign-hook.sh (release-signing.md §fallback).
if [ -f "$LOCAL_HOOK" ]; then
  echo "[sign] local signer present -> $LOCAL_HOOK"
  bash "$LOCAL_HOOK" "$SRC_DIR" && { echo "[sign] signed locally"; exit 0; }
  echo "[sign] local hook failed — falling through to remote provider"
fi

# 2) Remote provider (the capability gate from release-signing.md).
SIGN_REPO="${DXR_SIGN_REPO:-}"
if [ -z "$SIGN_REPO" ] || ! gh workflow view sign-artifact -R "$SIGN_REPO" >/dev/null 2>&1; then
  echo "[sign] WARN provider unreachable (DXR_SIGN_REPO='${SIGN_REPO:-unset}') — shipping UNSIGNED"
  exit 0
fi
echo "[sign] provider=$SIGN_REPO — folder-sign via sign-artifact"

TAG="browser-sign-$(cat "$CHROMIUM_SRC/chrome/VERSION" 2>/dev/null | awk -F= '/BUILD/{b=$2}/PATCH/{p=$2}END{print b"."p}')-$$"
ZIP="$(mktemp -d)/unsigned.zip"
( cd "$SRC_DIR" && powershell -NoProfile -Command "Compress-Archive -Path * -DestinationPath '$ZIP' -Force" )

echo "[sign] uploading unsigned.zip as prerelease $TAG on $SIGN_REPO"
gh release create "$TAG" -R "$SIGN_REPO" --prerelease --title "$TAG" --notes "DisplayXR Browser folder-sign" "$ZIP#unsigned.zip"
gh workflow run sign-artifact -R "$SIGN_REPO" -f release_tag="$TAG"

echo "[sign] waiting for sign-artifact to finish…"
gh run watch -R "$SIGN_REPO" "$(gh run list -R "$SIGN_REPO" --workflow sign-artifact --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status || {
  echo "[sign] WARN sign-artifact run failed — shipping UNSIGNED"; exit 0; }

OUTDIR="$(mktemp -d)"
gh run download -R "$SIGN_REPO" --name signed --dir "$OUTDIR"
powershell -NoProfile -Command "Expand-Archive -Path '$OUTDIR/signed.zip' -DestinationPath '$SRC_DIR' -Force"
gh release delete "$TAG" -R "$SIGN_REPO" --yes --cleanup-tag || true

echo "[sign] verifying Authenticode chain on chrome.exe"
powershell -NoProfile -Command "& { \$st=(Get-AuthenticodeSignature '$SRC_DIR/chrome.exe').Status; Write-Output \"status=\$st\"; if(\$st -ne 'Valid'){ exit 1 } }"
echo "[sign] done — signed + Valid"
