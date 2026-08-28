#!/usr/bin/env bash
# release.sh — publish a DisplayXR Browser preview to GitHub Releases.
#
# Expects a signed installer already built (installer/build_installer.sh + scripts/sign.sh).
# Creates a tagged GitHub Release in THIS repo with the installer attached, the preview label,
# and the security disclaimer in the notes. This is the download the website links to
# (docs/release-and-distribution.md), and it updates feed/feed.json — the update feed served
# at updates.displayxr.org.
#
# NOTE: the in-browser version check described in docs/release-and-distribution.md is DESIGNED,
# NOT SHIPPED (browser#154) — no version-check.js exists and nothing in the patch series polls
# for updates. The feed is written so it is correct when a consumer arrives; do not read the
# feed's existence as evidence that anything reads it yet.
#
# Set SECURITY=1 for a release whose point is a Chromium security rebase.
#
# Usage: scripts/release.sh <tag> <asset> [asset ...]
#   e.g. scripts/release.sh preview-150.0.7871.24 dist/DisplayXR-Browser-Preview-Setup-150.0.7871.24.1.exe
#        scripts/release.sh preview-0.1.21 dist/DisplayXR-Browser-Preview-Setup-0.1.21.exe dist/DisplayXR-Browser-0.1.21-arm64.apk
#
# N ASSETS, NOT ONE. The Android lane (.github/workflows/build-box-android.yml) produces an
# APK alongside the Windows installer, so a release can carry either or both. Everything
# platform-shaped below is derived from WHICH assets were passed:
#   * only a PE (.exe/.msi/.dll) gets the Authenticode check — running an APK through
#     Get-AuthenticodeSignature is meaningless and would report a scary Unknown;
#   * the notes describe the platforms actually shipped, and never claim Windows/D3D11 on
#     an Android-only release (preview-0.1.17 was exactly that);
#   * the feed is Windows-only by SCHEMA (feed/feed.json's `latest` holds one url/sha256/
#     size with no platform key), so it is written only when there is a Windows asset. A
#     multi-platform feed is a schema change and deliberately NOT invented here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"

TAG="${1:?usage: release.sh <tag> <asset> [asset ...]}"
shift
[ $# -ge 1 ] || { echo "[release] usage: release.sh <tag> <asset> [asset ...]"; exit 1; }
ASSETS=("$@")

WIN_ASSET=""     # the Windows installer, if this release carries one
APK_ASSET=""     # the Android APK, if this release carries one
for a in "${ASSETS[@]}"; do
  [ -f "$a" ] || { echo "[release] no asset at $a"; exit 1; }
  case "$a" in
    *.exe|*.msi) [ -n "$WIN_ASSET" ] || WIN_ASSET="$a" ;;
    *.apk)       [ -n "$APK_ASSET" ] || APK_ASSET="$a" ;;
  esac
done
[ -n "$WIN_ASSET" ] || [ -n "$APK_ASSET" ] || {
  echo "[release] none of the assets is a .exe/.msi or .apk — refusing to publish a release"
  echo "[release]   with nothing installable in it."; exit 1; }

# Warn (don't block) if the installer isn't Authenticode-signed.
# Windows PowerShell cannot resolve an MSYS "/c/..." path, so it silently returned an
# EMPTY status for a genuinely signed installer (hit on 0.1.5). Hand it a native path.
#
# PE FILES ONLY. This check is meaningless on an APK — an APK is a zip signed with the
# APK Signature Scheme, which Get-AuthenticodeSignature cannot read, so feeding it one
# yields "Unknown" and the notes would then advertise an unsigned-looking build for a
# reason that has nothing to do with signing. The APK's signing story is stated
# separately, and honestly, in the notes.
SIG=""
if [ -n "$WIN_ASSET" ]; then
  EXE_NATIVE="$(cygpath -w "$WIN_ASSET" 2>/dev/null || echo "$WIN_ASSET")"
  SIG=$(powershell -NoProfile -Command "(Get-AuthenticodeSignature '$EXE_NATIVE').Status" 2>/dev/null | tr -d '\r') || SIG=Unknown
  [ -n "$SIG" ] || SIG=Unknown
  [ "$SIG" = "Valid" ] || echo "[release] WARNING installer signature status = $SIG (publishing anyway)"
fi

# The platform paragraph and the signing line DESCRIBE THE ASSETS, they are not boilerplate.
#
# The Windows-only wording below is byte-identical to what every release through 0.1.20
# shipped — that path must not change. The other two exist because the old text was simply
# false off Windows: an Android release has no D3D11, no DirectComposition, and above all
# no installer that "chains/detects" the runtime. On Android the runtime is a separately
# installed APK and the vendor display plug-in ships INSIDE it (runtime ADR-038), so there
# is nothing to chain and saying otherwise sends users looking for a plug-in installer that
# does not exist.
WIN_PARA="A Chromium-based browser that renders the whole web normally **and** weaves glasses-free inline-3D for
\`inline-3d\` WebXR pages on DisplayXR hardware. Windows / D3D11 + DirectComposition. Requires a DisplayXR
3D display + the DisplayXR runtime and a display plug-in (the installer chains/detects them); on any
other machine it is an ordinary browser."

ANDROID_PARA="A Chromium-based browser that renders the whole web normally **and** weaves glasses-free inline-3D for
\`inline-3d\` WebXR pages on DisplayXR hardware. Android / arm64, on a DisplayXR 3D display device.
Requires the DisplayXR runtime APK installed separately — the vendor display plug-in ships inside that
runtime APK, so there is nothing else to install; on any other device it is an ordinary browser."

if [ -n "$WIN_ASSET" ] && [ -n "$APK_ASSET" ]; then
  PLATFORM_PARA="$WIN_PARA

**Android (arm64)** is also published in this release as an \`.apk\`. It needs the DisplayXR runtime APK
installed separately; the vendor display plug-in ships inside that runtime APK."
elif [ -n "$APK_ASSET" ]; then
  PLATFORM_PARA="$ANDROID_PARA"
else
  PLATFORM_PARA="$WIN_PARA"
fi

# Signing, per asset. The Windows-only case emits exactly the line it always did.
SIGNING_PARA=""
[ -n "$WIN_ASSET" ] && SIGNING_PARA="Installer signature: **$SIG**."
if [ -n "$APK_ASSET" ]; then
  APK_LINE="Android APK: **debug-key self-signed** (Chromium's checked-in debug keystore). A release keystore is
not wired up yet, so Android will warn on install and the APK is **not** upgrade-compatible with a future
signed build — expect to uninstall before taking one."
  if [ -n "$SIGNING_PARA" ]; then SIGNING_PARA="$SIGNING_PARA

$APK_LINE"; else SIGNING_PARA="$APK_LINE"; fi
fi

NOTES="$(cat <<EOF
**DisplayXR Browser — Developer Preview** · built on Chromium \`$CHROMIUM_TAG\`

$PLATFORM_PARA

> ⚠️ **Developer preview.** Rebased ~monthly onto Chrome stable, but **not** maintained to Chrome's
> mid-cycle security cadence — **don't use it for sensitive browsing**; use your primary browser for
> banking, etc. See the [maintenance policy](https://github.com/DisplayXR/displayxr-browser/blob/main/docs/maintenance-policy.md).

$SIGNING_PARA
EOF
)"

echo "[release] creating GitHub Release $TAG with ${#ASSETS[@]} asset(s):"
for a in "${ASSETS[@]}"; do echo "[release]   $(basename "$a")"; done
# NOT --prerelease, and explicitly --latest.
#
# Every release used to be flagged pre-release, which GitHub excludes from both
# the repo sidebar's "Releases" panel and /releases/latest. The practical result:
# the front page of the repo advertised 0.1.8 as the newest build for ELEVEN
# releases, and the permanent releases/latest/download/... alias 404d the whole
# time. "Developer preview" is communicated by the title, the notes and the
# maintenance policy — it does not need a flag whose only mechanical effect is
# to hide the release from everyone looking for it.
#
# --latest is passed explicitly rather than relying on GitHub's default: the
# default is `legacy` inference, and it is exactly what got stuck on 0.1.8 while
# six NEWER non-prerelease releases went by without moving the marker. State it.
gh release create "$TAG" -R DisplayXR/displayxr-browser \
  --title "DisplayXR Browser Preview ($CHROMIUM_TAG)" \
  --notes "$NOTES" \
  --latest \
  "${ASSETS[@]}"

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
echo "[release] displayxr-runtime/versions.json[browser] should now read $TAG."

# ── Update the published update feed (browser#154) ────────────────────────────────────
# This script used to only PRINT that a feed was consumed, and never wrote one. The feed
# sat at 0.1.5 / Chromium 150 through five releases and a milestone bump, because nothing
# contradicted the message. A release that does not update the feed is a release nobody
# installed can learn about, so writing it is part of publishing, not a follow-up chore.
#
# Version comes from the TAG (preview-0.1.18 -> 0.1.18), not from chrome/VERSION: the
# marketing version is what a user compares against, and it is the number -DVERSION
# stamped into the installer.
#
# WINDOWS ONLY, BY SCHEMA. feed/feed.json's `latest` is ONE object with one `url`, one
# `sha256` and one `size` and no platform key (see docs/auto-update-design.md and
# scripts/update-feed.sh, which emits that same shape). It therefore cannot describe an
# APK at all. Rather than invent a schema here, an Android-only release SKIPS the feed and
# says so; a mixed release writes the Windows entry exactly as a Windows-only release
# would. Teaching the feed about platforms is tracked as follow-up work, not smuggled in.
VERSION="${TAG#preview-}"
FEED="$REPO/feed/feed.json"
if [ -z "$WIN_ASSET" ]; then
  echo "[release] no Windows asset — SKIPPING the feed update."
  echo "[release]   feed/feed.json's schema has one url/sha256/size and no platform key,"
  echo "[release]   so it cannot represent an APK. The feed still advertises the last"
  echo "[release]   Windows build, which is correct: that is the only thing it can describe."
elif [ ! -f "$FEED" ]; then
  echo "[release] WARNING no feed at $FEED — skipping the feed update (browser#154)"
else
  SHA256="$(sha256sum "$WIN_ASSET" | cut -d' ' -f1)"
  SIZE="$(wc -c < "$WIN_ASSET" | tr -d ' ')"
  RELEASED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # ASK THE RELEASE what the asset is called; never assume it.
  #
  # The upload above no longer passes a `#label` suffix, so the asset's displayed name and
  # its stored filename are the same thing again. Keep asking the release anyway: this
  # lookup is what caught the label bug in the first place. When the label was set, gh's
  # `#` suffix set the DISPLAY name, not the stored filename, and writing the assumed name
  # into the feed produced a download URL that 404s -- in a file whose entire job is to
  # hand out a working download link, and nothing would have noticed until a user clicked
  # it. Never assume the asset name; the release is the only authority on it.
  ASSET="$(gh release view "$TAG" -R DisplayXR/displayxr-browser --json assets \
             --jq '.assets[] | select(.name|endswith(".exe")) | .name' | head -1)"
  [ -n "$ASSET" ] || { echo "[release] ERROR release $TAG has no .exe asset — not writing a feed URL"; exit 1; }
  URL="https://github.com/DisplayXR/displayxr-browser/releases/download/$TAG/$ASSET"
  # And prove it resolves before publishing it. A feed entry is only as good as its URL.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -L -m 60 -r 0-0 "$URL" || echo 000)"
  case "$CODE" in
    200|206) echo "[release] asset URL verified ($CODE): $URL" ;;
    *) echo "[release] ERROR asset URL returned $CODE: $URL"
       echo "[release]   refusing to write a feed that points at a download nobody can fetch."
       exit 1 ;;
  esac
  # SECURITY=1 marks a release whose point is a Chromium security rebase. Callers set it;
  # defaulting it to false is the safe direction (an under-claimed release is not a lie,
  # an over-claimed one is).
  SECURITY="${SECURITY:-false}"
  python - "$FEED" "$VERSION" "$CHROMIUM_TAG" "$URL" "$SHA256" "$SIZE" "$RELEASED" "$SECURITY" <<'PY'
import json, sys
feed_path, version, chromium, url, sha256, size, released, security = sys.argv[1:9]
with open(feed_path, encoding='utf-8') as f:
    feed = json.load(f)
feed['latest'] = {
    'version': version,
    'chromium': chromium,
    'url': url,
    'sha256': sha256,
    'size': int(size),
    'released': released,
    'security': security.lower() in ('1', 'true', 'yes'),
}
with open(feed_path, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(feed, f, indent=2)
    f.write('\n')
print('[release] feed updated -> %s (chromium %s, security=%s)' % (version, chromium, security))
PY
  echo "[release] COMMIT AND PUSH $FEED — pages.yml publishes it to updates.displayxr.org."
  echo "[release]   git add feed/feed.json && git commit -m 'feed: $VERSION' && git push"
fi
echo "[release] the website download button reads /releases (NOT /releases/latest — every"
echo "[release]   preview is a GitHub pre-release, which that alias excludes)."
