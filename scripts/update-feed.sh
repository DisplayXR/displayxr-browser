#!/usr/bin/env bash
# update-feed.sh — generate/refresh the auto-update feed (browser#38 publish step,
# schema per docs/auto-update-design.md).
#
# The feed is what turns "we built a patch" into "users get the patch". It is the ONLY
# thing the updater trusts for *which* version to take — but NOT for whether the bytes are
# safe: the updater independently verifies Authenticode + this sha256 before executing.
# That's why the hash is computed here from the actual artifact and never hand-written.
#
# Host-agnostic on purpose: it emits JSON on stdout (or --out). Where it gets published
# (GitHub Pages vs a Release asset) is still an open decision on #40 and does not affect
# this script.
#
# Usage:
#   scripts/update-feed.sh --version 0.1.5 --chromium 150.0.7871.129 \
#       --installer dist/DisplayXR-Browser-Preview-Setup-0.1.5.exe \
#       --url https://github.com/DisplayXR/displayxr-browser/releases/download/preview-150.0.7871.129/DisplayXR-Browser-Preview-Setup-0.1.5.exe \
#       [--security] [--rollout 10] [--minimum 0.1.3] [--out update.json]
#
# --rollout is the staged-rollout percentage (browser#40 §4). Start a release small
# (e.g. 10), then re-run with 100 to go wide. This is the blast-radius limit whose absence
# is the only reason #38 still needs a human to promote the feed flip.
set -euo pipefail

VERSION=""; CHROMIUM=""; INSTALLER=""; URL=""; OUT=""
SECURITY="false"; ROLLOUT="100"; MINIMUM=""; CHANNEL="preview"

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2;;
    --chromium)  CHROMIUM="$2"; shift 2;;
    --installer) INSTALLER="$2"; shift 2;;
    --url)       URL="$2"; shift 2;;
    --out)       OUT="$2"; shift 2;;
    --minimum)   MINIMUM="$2"; shift 2;;
    --rollout)   ROLLOUT="$2"; shift 2;;
    --channel)   CHANNEL="$2"; shift 2;;
    --security)  SECURITY="true"; shift;;
    *) echo "update-feed: unknown arg $1" >&2; exit 2;;
  esac
done

for req in VERSION CHROMIUM INSTALLER URL; do
  [ -n "${!req}" ] || { echo "update-feed: --${req,,} is required" >&2; exit 2; }
done
[ -f "$INSTALLER" ] || { echo "update-feed: installer not found: $INSTALLER" >&2; exit 2; }
case "$ROLLOUT" in ''|*[!0-9]*) echo "update-feed: --rollout must be 0-100" >&2; exit 2;; esac
[ "$ROLLOUT" -ge 0 ] && [ "$ROLLOUT" -le 100 ] || { echo "update-feed: --rollout must be 0-100" >&2; exit 2; }

# Hash + size from the ACTUAL artifact — never hand-entered. A feed whose hash doesn't
# match the bytes just makes every client refuse the update (fail-closed), which is safe
# but silently stalls the security cadence, so compute it here.
SHA256="$(sha256sum "$INSTALLER" | awk '{print $1}')"
SIZE="$(wc -c < "$INSTALLER" | tr -d ' ')"
RELEASED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Warn loudly if the artifact isn't Authenticode-signed — the updater will refuse it, so
# publishing it would be a no-op that looks like a shipped release.
if command -v powershell >/dev/null 2>&1; then
  WINPATH="$(cygpath -w "$INSTALLER" 2>/dev/null || echo "$INSTALLER")"
  SIG="$(powershell -NoProfile -Command "(Get-AuthenticodeSignature '$WINPATH').Status" 2>/dev/null | tr -d '\r')" || SIG="Unknown"
  if [ "$SIG" != "Valid" ]; then
    echo "update-feed: WARNING signature status = ${SIG:-Unknown} — clients verify Authenticode and will REFUSE this build" >&2
  fi
fi

MIN_JSON="null"
[ -n "$MINIMUM" ] && MIN_JSON="\"$MINIMUM\""

read -r -d '' FEED <<JSON || true
{
  "schema": 1,
  "channel": "${CHANNEL}",
  "latest": {
    "version": "${VERSION}",
    "chromium": "${CHROMIUM}",
    "url": "${URL}",
    "sha256": "${SHA256}",
    "size": ${SIZE},
    "released": "${RELEASED}",
    "security": ${SECURITY}
  },
  "minimum": ${MIN_JSON},
  "rollout": ${ROLLOUT}
}
JSON

if [ -n "$OUT" ]; then
  printf '%s\n' "$FEED" > "$OUT"
  echo "update-feed: wrote $OUT (version=$VERSION rollout=$ROLLOUT security=$SECURITY)" >&2
else
  printf '%s\n' "$FEED"
fi
