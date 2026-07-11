#!/usr/bin/env bash
# remote-build.sh — build the DisplayXR Browser on the remote signing/build box, freeing this
# machine from the multi-hour Chromium compile. Dispatches the `build-browser` workflow on the
# provider repo (the box named by $DXR_SIGN_REPO — same box that signs releases), watches it, and
# downloads the resulting browser tree (+ optional installer) into dist/.
#
# The workflow itself lives in the PROVIDER repo (LeiaInc/codesign-runner), not here — the runner
# is registered there and the box has the toolchain (mirrors build-signed-release.yml). This script
# is the local, any-OS dispatcher (needs only `gh` + bash).
#
# Usage:
#   scripts/remote-build.sh [--tag 150.0.7871.24] [--ref main] [--no-sign] [--installer]
#   DXR_SIGN_REPO is read from ../displayxr-runtime/.env.local if not already in the env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

# Resolve the provider/build box (same var release signing uses).
if [ -z "${DXR_SIGN_REPO:-}" ]; then
  for env in "$REPO/../displayxr-runtime/.env.local" "$REPO/.env.local"; do
    [ -f "$env" ] && . "$env" && break
  done
fi
: "${DXR_SIGN_REPO:?set DXR_SIGN_REPO (the build/signing box repo), e.g. in displayxr-runtime/.env.local}"

TAG=""; REF="main"; SIGN="true"; INSTALLER="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --ref) REF="$2"; shift 2;;
    --no-sign) SIGN="false"; shift;;
    --installer) INSTALLER="true"; shift;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

echo "[remote-build] dispatching build-browser on $DXR_SIGN_REPO (ref=$REF tag=${TAG:-config.env} sign=$SIGN installer=$INSTALLER)"
gh workflow run build-browser.yml -R "$DXR_SIGN_REPO" \
  -f chromium_tag="$TAG" -f browser_ref="$REF" -f sign="$SIGN" -f build_installer="$INSTALLER"

# Grab the run id (newest build-browser run) and watch it.
sleep 5
RUN=$(gh run list -R "$DXR_SIGN_REPO" --workflow build-browser.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "[remote-build] run $RUN — https://github.com/$DXR_SIGN_REPO/actions/runs/$RUN"
echo "[remote-build] watching (Chromium build is multi-hour on the box)…"
gh run watch -R "$DXR_SIGN_REPO" "$RUN" --exit-status || { echo "[remote-build] run failed — see the URL above"; exit 1; }

echo "[remote-build] downloading the browser tree into dist/"
mkdir -p "$REPO/dist"
gh run download -R "$DXR_SIGN_REPO" "$RUN" --name displayxr-browser-tree --dir "$REPO/dist/DisplayXR-Browser" || true
if [ "$INSTALLER" = "true" ]; then
  gh run download -R "$DXR_SIGN_REPO" "$RUN" --name displayxr-browser-installer --dir "$REPO/dist" || true
fi
echo "[remote-build] done. Copy dist/DisplayXR-Browser to a DisplayXR display box and verify the weave"
echo "               (docs/rebase-runbook.md §6) — the remote build offloads the COMPILE, not the eyeball."
