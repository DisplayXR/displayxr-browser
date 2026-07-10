# Branding

DisplayXR Browser presents as a **Chromium-based browser under our own name** — like Brave/Edge, and
explicitly **not** "Chrome".

## What's here
- **`BRANDING`** — the product-strings file copied over `chrome/app/theme/chromium/BRANDING` by
  `scripts/brand.sh`. Sets `COMPANY_*`, `PRODUCT_*`, `COPYRIGHT`, `MAC_BUNDLE_ID`. This is the P0-level
  rebrand (window title, About page, exe metadata).

## TODO (P1/P2 — additive, not required for the P0 feasibility gate)
- **Icons.** Replace the product logos/icons under `chrome/app/theme/chromium/` (`product_logo_*.png`,
  the win `.ico` / `tiles/` assets). Keep the same filenames so the resource pipeline picks them up with
  no `.grd` edits. Source art lands here as `icons/`.
- **User-agent tag.** Append a `DisplayXRBrowser/<version>` token to the UA in
  `components/embedder_support/user_agent_utils.cc` (a small, additive edit — a UA that identifies the
  browser under our name while staying Chromium-compatible). Document the exact UA string here once set.

Keep this rebase-stable: `BRANDING`'s format is long-lived, and the icon filenames/UA edit site rarely
move — so branding almost never conflicts on a milestone rebase.
