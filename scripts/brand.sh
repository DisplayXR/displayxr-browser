#!/usr/bin/env bash
# brand.sh — apply DisplayXR Browser product branding onto the Chromium checkout.
#
# Spike level (P0/P1): product strings via chrome/app/theme/chromium/BRANDING. Icons + a
# DisplayXR user-agent tag are TODO (tracked in branding/README.md). Called by build.sh, or
# stand-alone after fetch.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
source "$HERE/config.env"

DST="$CHROMIUM_SRC/chrome/app/theme/chromium/BRANDING"
echo "[brand] writing product strings -> $DST"
cp "$REPO/branding/BRANDING" "$DST"

echo "[brand] BRANDING now:"
sed -n '1,7p' "$DST"

# --- TODO (P1/P2 branding, additive, not required for the P0 gate) ---
#  * Product icons: replace chrome/app/theme/chromium/win/tiles/*, product_logo_*.png, and the
#    .ico resources; keep the same filenames so the resource pipeline picks them up unchanged.
#  * User-agent tag: append a "DisplayXRBrowser/<ver>" token in
#    components/embedder_support/user_agent_utils.cc (a Chromium-based UA under our name, like
#    Brave/Edge — NOT "Chrome"). Small, additive; see branding/README.md.
echo "[brand] done (product strings). Icons + UA tag are branding/README.md TODOs."
