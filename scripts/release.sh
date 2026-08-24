#!/usr/bin/env bash
# release.sh — publish a DisplayXR Browser preview to GitHub Releases.
#
# Expects a signed installer already built (installer/build_installer.sh + scripts/sign.sh).
# Creates a tagged GitHub Release in THIS repo with the installer attached, the preview label,
# and the security disclaimer in the notes. This is the download the website links to, and the
# feed the in-browser version check reads (docs/release-and-distribution.md).
#
# Usage: scripts/release.sh <tag> <path-to-signed-installer.exe>
#   e.g. scripts/release.sh preview-150.0.7871.24 dist/DisplayXR-Browser-Preview-Setup-150.0.7871.24.1.exe
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"

TAG="${1:?usage: release.sh <tag> <installer.exe>}"
EXE="${2:?usage: release.sh <tag> <installer.exe>}"
[ -f "$EXE" ] || { echo "[release] no installer at $EXE"; exit 1; }

# Warn (don't block) if the installer isn't Authenticode-signed.
# Windows PowerShell cannot resolve an MSYS "/c/..." path, so it silently returned an
# EMPTY status for a genuinely signed installer (hit on 0.1.5). Hand it a native path.
EXE_NATIVE="$(cygpath -w "$EXE" 2>/dev/null || echo "$EXE")"
SIG=$(powershell -NoProfile -Command "(Get-AuthenticodeSignature '$EXE_NATIVE').Status" 2>/dev/null | tr -d '\r') || SIG=Unknown
[ -n "$SIG" ] || SIG=Unknown
[ "$SIG" = "Valid" ] || echo "[release] WARNING installer signature status = $SIG (publishing anyway)"

NOTES="$(cat <<EOF
**DisplayXR Browser — Developer Preview** · built on Chromium \`$CHROMIUM_TAG\`

A Chromium-based browser that renders the whole web normally **and** weaves glasses-free inline-3D for
\`inline-3d\` WebXR pages on DisplayXR hardware. Windows / D3D11 + DirectComposition. Requires a DisplayXR
3D display + the DisplayXR runtime and a display plug-in (the installer chains/detects them); on any
other machine it is an ordinary browser.

> ⚠️ **Developer preview.** Rebased ~monthly onto Chrome stable, but **not** maintained to Chrome's
> mid-cycle security cadence — **don't use it for sensitive browsing**; use your primary browser for
> banking, etc. See the [maintenance policy](https://github.com/DisplayXR/displayxr-browser/blob/main/docs/maintenance-policy.md).

Installer signature: **$SIG**.
EOF
)"

echo "[release] creating GitHub Release $TAG with $(basename "$EXE")"
gh release create "$TAG" -R DisplayXR/displayxr-browser \
  --title "DisplayXR Browser Preview ($CHROMIUM_TAG)" \
  --notes "$NOTES" \
  --prerelease \
  "$EXE#DisplayXR-Browser-Preview-Setup.exe"

# --- pin the release into the org's tested-together matrix -------------------
# displayxr-runtime/versions.json is the canonical pin matrix (its
# docs/specs/runtime/versions-json-autobump.md). The browser is a member of it,
# so a published release has to move the `browser` field or the matrix silently
# rots -- which is exactly the drift the auto-bump flow exists to kill.
#
# This runs from the release operator's own gh auth (the signing box), not a
# GitHub App: release.sh is invoked by hand, and the operator already has push
# on displayxr-runtime. Nothing to provision.
#
# Non-fatal on purpose. The release is already published and downloadable at
# this point; a dispatch hiccup must not make a good release look failed.
BUMP_CMD="gh workflow run versions-bump.yml -R DisplayXR/displayxr-runtime -f field=browser -f tag=$TAG -f source_repo=DisplayXR/displayxr-browser"
echo "[release] dispatching versions.json[browser] -> $TAG"
if gh api -X POST repos/DisplayXR/displayxr-runtime/dispatches --input - <<EOF >/dev/null
{"event_type":"versions-bump","client_payload":{"field":"browser","tag":"$TAG","source_repo":"DisplayXR/displayxr-browser"}}
EOF
then
    echo "[release]  OK  versions-bump dispatched."
else
    echo "[release] WARNING versions-bump dispatch failed. Bump it by hand:"
    echo "[release]   $BUMP_CMD"
fi

echo "[release] done — https://github.com/DisplayXR/displayxr-browser/releases/tag/$TAG"
echo "[release] the in-browser version check + the website download button read this release feed."
echo "[release] displayxr-runtime/versions.json[browser] should now read $TAG."
