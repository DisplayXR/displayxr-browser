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
  "$EXE"

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
VERSION="${TAG#preview-}"
FEED="$REPO/feed/feed.json"
if [ ! -f "$FEED" ]; then
  echo "[release] WARNING no feed at $FEED — skipping the feed update (browser#154)"
else
  SHA256="$(sha256sum "$EXE" | cut -d' ' -f1)"
  SIZE="$(wc -c < "$EXE" | tr -d ' ')"
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
