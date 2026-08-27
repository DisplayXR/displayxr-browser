# Release & distribution

How a DisplayXR Browser preview reaches users, and how updates work. Cadence + security posture are
in [maintenance-policy.md](maintenance-policy.md) (the locked §6 decision).

## The release flow
Per monthly milestone (after the rebase runbook's build + weave-verify):
```bash
installer/build_installer.sh                       # stages tree → INNER-signs first-party binaries → makensis → Setup.exe
bash C:/displayxr-signing/sign-hook.sh dist        # outer-sign the Setup.exe (or set SIGN_CMD to sign in-build)
scripts/release.sh preview-<ver> dist/DisplayXR-Browser-Preview-Setup-<ver>.<n>.exe
```
`release.sh` creates a **prerelease** GitHub Release in `displayxr-browser` with the signed installer
attached (as `DisplayXR-Browser-Preview-Setup-<version>.exe`), the preview label, and the security disclaimer in
the notes. That release is:
- the **download** the website links to (below), and
- the **feed** the in-browser version check reads (below).
- the **pin** `displayxr-runtime/versions.json[browser]`: `release.sh` ends by dispatching a
  `versions-bump` event at the runtime hub, which moves that field to this tag. Non-fatal — if
  it fails, re-run `gh workflow run versions-bump.yml -R DisplayXR/displayxr-runtime -f
  field=browser -f tag=<tag> -f source_repo=DisplayXR/displayxr-browser`. The browser's pin is
  `preview-X.Y.Z`, which the runtime's bump validator accepts for this field only.

### Two layers of signing
- **Inner (the installed browser):** `build_installer.sh` runs `scripts/sign.sh "$STAGE"` on the staged
  tree *before* `makensis` packs it, so `chrome.exe` / `chrome.dll` and the ELF/WER/proxy/pwa-launcher
  stubs are Authenticode-signed. This is what SmartScreen re-checks when the user **runs** the browser,
  and what enterprise publisher-allowlisting keys on. Only **first-party** binaries are signed — bundled
  third-party redistributables (`vulkan-1.dll`, `vk_swiftshader*`, `d3dcompiler_47.dll`, `dxcompiler.dll`,
  `dxil.dll`, `openxr_loader.dll`) keep their original signatures. Skip with `SIGN_INNER=0`.
- **Outer (the installer):** the `Setup.exe` (+ its uninstaller) is signed either in-build via `SIGN_CMD`
  (a runner-local `signtool` wrapper → NSIS `!finalize`) or post-hoc via the folder `sign-hook`. This is
  what SmartScreen checks on **download**.

Signing never gates the release — if the signer is unreachable, sign.sh warns and the unsigned artifact
ships (see [`release-signing.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/specs/runtime/release-signing.md)).

## Website download
`displayxr-website` carries the **Download** button + the preview/security page. It links to the latest
`displayxr-browser` GitHub Release (`/releases/latest`), labelled **"Developer Preview — Windows,
requires a DisplayXR 3D display"**, and restates the disclaimer. The website's mechanical facts auto-sync
(`sync-org.yml`); the download section + policy prose are hand-authored (via `/sync-website`).

## Updates — lightweight version check, NOT silent auto-update
The preview deliberately does **not** ship an Omaha-style silent updater (heavier, and a stronger
security promise than a preview should make). Instead:

- On load, the **start page** fetches the update feed at `https://updates.displayxr.org/feed.json`
  (written by `scripts/release.sh` on every publish) and compares its `chromium` field to the
  running build's Chromium version.
- If the feed is newer, it shows a **"new version available → download"** banner linking to the
  release asset — no silent install. Security rebases (`"security": true` in the feed) are labelled
  as such.
- A monthly release cadence makes this check meaningful without an updater.

**Two things here are load-bearing and are easy to get wrong:**

- **NOT `/releases/latest`.** Every preview is published as a GitHub *pre-release*, and that alias
  excludes pre-releases — it still resolves to **0.1.8** today. The feed is the source of truth.
  (`displayxr-website` links to `/releases`, the list, for the same reason.)
- **NOT `navigator.userAgent` for the running version.** Chromium freezes the version in the UA
  string: a browser running `151.0.7922.174` reports `Chrome/151.0.0.0`. Comparing that against the
  feed makes an up-to-date browser look permanently out of date and nags it on every page load. The
  version must come from `navigator.userAgentData.getHighEntropyValues(['fullVersionList'])`, picking
  the entry **by brand** (the list carries a GREASE decoy at a deliberately unstable index). If those
  hints are unavailable, the check says nothing rather than guessing.

Implementation: the reusable check lives in
[`displayxr-web/js/version-check.js`](https://github.com/DisplayXR/displayxr-web/blob/main/js/version-check.js)
(feature-detect + compare + banner) and **is shipping** — the browser's start page is `displayxr-web`'s
root, which is what lets this reach users with no browser patch at all. It gates on
`window.XRDisplayLayer`, so it is inert in every other browser; the pure comparison logic is unit-tested
in `test/version-check.test.mjs`. A future small patch could also surface it as a native infobar. Either
way it stays a **check + link**, never
a silent update.

## First-run
Handled by the installer (`installer/DisplayXRBrowserInstaller.nsi` `.onInstSuccess`): detects a DisplayXR
3D display + registered DP; if absent, a one-time notice + the disclaimer (the weave no-ops → normal
browser). See `installer/README.md`.
