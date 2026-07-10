# Release & distribution

How a DisplayXR Browser preview reaches users, and how updates work. Cadence + security posture are
in [maintenance-policy.md](maintenance-policy.md) (the locked §6 decision).

## The release flow
Per monthly milestone (after the rebase runbook's build + weave-verify):
```bash
installer/build_installer.sh                       # → dist/DisplayXR-Browser-Preview-Setup-<ver>.<n>.exe
scripts/sign.sh dist                               # EV-sign (folder-sign via $DXR_SIGN_REPO)
scripts/release.sh preview-<ver> dist/DisplayXR-Browser-Preview-Setup-<ver>.<n>.exe
```
`release.sh` creates a **prerelease** GitHub Release in `displayxr-browser` with the signed installer
attached (as `DisplayXR-Browser-Preview-Setup.exe`), the preview label, and the security disclaimer in
the notes. That release is:
- the **download** the website links to (below), and
- the **feed** the in-browser version check reads (below).

Signing never gates the release — if `$DXR_SIGN_REPO` is unreachable, the unsigned installer ships with a
warning (see [`release-signing.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/specs/runtime/release-signing.md)).

## Website download
`displayxr-website` carries the **Download** button + the preview/security page. It links to the latest
`displayxr-browser` GitHub Release (`/releases/latest`), labelled **"Developer Preview — Windows,
requires a DisplayXR 3D display"**, and restates the disclaimer. The website's mechanical facts auto-sync
(`sync-org.yml`); the download section + policy prose are hand-authored (via `/sync-website`).

## Updates — lightweight version check, NOT silent auto-update
The preview deliberately does **not** ship an Omaha-style silent updater (heavier, and a stronger
security promise than a preview should make). Instead:

- On launch, the browser checks the **GitHub Releases API**
  (`https://api.github.com/repos/DisplayXR/displayxr-browser/releases/latest`) and compares the latest
  tag to its own build version.
- If newer, it surfaces a **"new version available → download"** prompt linking to the release — no
  silent install.
- A monthly release cadence makes this check meaningful without an updater.

Implementation: the reusable check lives in
[`displayxr-web/js/version-check.js`](https://github.com/DisplayXR/displayxr-web/blob/main/js/version-check.js)
(feature-detect + compare + banner). The browser's start page (a `displayxr-web`-hosted page) runs it; a
future small patch can also surface it as a native infobar. Either way it stays a **check + link**, never
a silent update.

## First-run
Handled by the installer (`installer/DisplayXRBrowserInstaller.nsi` `.onInstSuccess`): detects a DisplayXR
3D display + registered DP; if absent, a one-time notice + the disclaimer (the weave no-ops → normal
browser). See `installer/README.md`.
