# Branding

DisplayXR Browser presents as a **Chromium-based browser under our own name** — like Brave/Edge, and
explicitly **not** "Chrome".

## What's here
- **`BRANDING`** — the product-strings file copied over `chrome/app/theme/chromium/BRANDING` by
  `scripts/brand.sh`. Sets `COMPANY_*`, `PRODUCT_*`, `COPYRIGHT`, `MAC_BUNDLE_ID`. This is the P0-level
  rebrand (window title, About page, exe metadata).
- **`initial_preferences`** — the default landing page. `scripts/package.sh` copies it into the staged
  tree, so the installer's `File /r` drops it **next to `chrome.exe`**, which is where Chromium looks
  for it. Startup and the home button both point at the inline-3D samples
  (<https://displayxr.github.io/displayxr-web/>) — the natural first thing to see in a browser whose
  whole point is the weave, and it links on to the gallery.

  Two things to know before changing it:
  - **It seeds a NEW profile only.** An existing profile keeps whatever it already has, so a dev who
    has run the browser before will not see the change without a fresh profile
    (`--user-data-dir=<empty path>`). That is correct for a *default* — it is a starting point, not a
    policy, and the user stays free to change their homepage.
  - **Strict JSON, no comments.** `restore_on_startup: 4` is Chromium's "open these URLs" value
    (0 = new tab page, 1 = last session). Keep the URL in both `homepage` and `session.startup_urls`
    or the home button and the startup page disagree.

  Deliberately **not** a source patch: a homepage string does not justify a 55th entry in a series that
  is regenerated and rebased against a new milestone tag every month. This is the mechanism Chromium
  provides for exactly this, and it costs nothing on rebase.

## TODO (P1/P2 — additive, not required for the P0 feasibility gate)
- **Icons.** Replace the product logos/icons under `chrome/app/theme/chromium/` (`product_logo_*.png`,
  the win `.ico` / `tiles/` assets). Keep the same filenames so the resource pipeline picks them up with
  no `.grd` edits. Source art lands here as `icons/`.
- **User-agent tag.** Append a `DisplayXRBrowser/<version>` token to the UA in
  `components/embedder_support/user_agent_utils.cc` (a small, additive edit — a UA that identifies the
  browser under our name while staying Chromium-compatible). Document the exact UA string here once set.

Keep this rebase-stable: `BRANDING`'s format is long-lived, and the icon filenames/UA edit site rarely
move — so branding almost never conflicts on a milestone rebase.
