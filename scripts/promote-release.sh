#!/usr/bin/env bash
# promote-release.sh — the go-wide flip for a STAGED release (browser#38).
#
# A staged release (STAGED=1 release.sh) publishes a PRE-release and writes the feed at a
# small --rollout. This script is the ONE human-approved promotion: it flips the GitHub
# release to a full latest release, sets the feed's rollout to 100, and moves the org pin.
# In pipeline.yml it runs inside the protected `go-live` environment, so executing it IS
# the approval.
#
# Honesty note (until browser#40's updater ships): `rollout` has NO consumer today — the
# start-page version check offers the newest feed entry to everyone regardless. The staged
# flip is exercised now so the day the updater lands the pipeline does not change shape.
#
# Usage: scripts/promote-release.sh <tag>        e.g. scripts/promote-release.sh preview-0.1.22
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TAG="${1:?usage: promote-release.sh <tag>}"
VERSION="${TAG#preview-}"
FEED="$REPO/feed/feed.json"
PY="$(command -v python || command -v python3)"

# The release must exist and be the one the feed describes — promoting a tag the feed has
# moved past would silently un-stage the WRONG version.
gh release view "$TAG" -R DisplayXR/displayxr-browser --json tagName >/dev/null
FEED_VERSION="$("$PY" -c "import json;print(json.load(open('$FEED',encoding='utf-8'))['latest']['version'])")"
if [ "$FEED_VERSION" != "$VERSION" ]; then
  echo "[promote] ERROR feed/feed.json describes $FEED_VERSION, not $VERSION — refusing to"
  echo "[promote]   promote a release the feed has moved past. Re-stage or fix the feed first."
  exit 1
fi

echo "[promote] $TAG: pre-release -> full release (+ latest marker)"
gh release edit "$TAG" -R DisplayXR/displayxr-browser --prerelease=false --latest

echo "[promote] feed rollout -> 100"
"$PY" - "$FEED" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    feed = json.load(f)
feed['rollout'] = 100
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(feed, f, indent=2)
    f.write('\n')
PYEOF

# The org pin moves at PROMOTE, not at stage — versions.json means "tested together and
# live", and a staged pre-release is neither yet. Non-fatal, same as release.sh: from CI
# the default token is repo-scoped and cannot dispatch into displayxr-runtime, so print
# the manual command rather than failing an otherwise-complete promotion.
echo "[promote] dispatching versions.json[browser] -> $TAG"
if gh api -X POST repos/DisplayXR/displayxr-runtime/dispatches --input - <<EOF >/dev/null
{"event_type":"versions-bump","client_payload":{"field":"browser","tag":"$TAG","source_repo":"DisplayXR/displayxr-browser"}}
EOF
then
  echo "[promote]  OK  versions-bump dispatched."
else
  echo "[promote] WARNING versions-bump dispatch failed (repo-scoped token?). Run by hand:"
  echo "[promote]   gh api -X POST repos/DisplayXR/displayxr-runtime/dispatches -f event_type=versions-bump ..."
  echo "[promote]   or: gh workflow run versions-bump.yml -R DisplayXR/displayxr-runtime -f field=browser -f tag=$TAG -f source_repo=DisplayXR/displayxr-browser"
fi

echo "[promote] done — commit and push feed/feed.json (pipeline.yml's promote job does this)."
