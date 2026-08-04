# Installer — `DisplayXR-Browser-Preview-Setup.exe`

A signed NSIS installer for the DisplayXR Browser developer preview. Reuses the runtime installer's
patterns (two-pass signed uninstaller, 64-bit registry view, ARP entry).

## What it does
1. **Installs the browser** (the staged static Chromium tree from `scripts/package.sh`) into
   `%ProgramFiles%\DisplayXR\Browser`, with Start-menu + desktop shortcuts and an Add/Remove entry.
2. **Chains-or-requires the runtime, by VERSION not just presence (#68).** The DisplayXR runtime + a
   display plug-in are the weave prerequisites. The installer reads both `InstallPath` and `Version`
   from `HKLM\Software\DisplayXR\Runtime` and compares `Version` against `MIN_RUNTIME_VERSION`
   (`VersionCompare` from `WordFunc.nsh`; a missing or unparseable `Version` counts as **too old**,
   never as fine):
   - **new enough** → left alone;
   - **missing or too old** → the bundled runtime setup is chained silently (`/S /NOSTART`, like the
     meta-bundle) when one was bundled with `-DRUNTIME_SETUP=…`. Note this now upgrades an
     out-of-date runtime; it used to chain only when *no* runtime was present.
   - **too old with nothing bundled** → an explicit warning naming both the installed and the required
     version. This is the case nothing else catches: an out-of-date runtime still passes
     `displayxr-cli selftest`, so the first-run notice below stays silent and the user would otherwise
     get a browser whose 3D features quietly misbehave.

   `MIN_RUNTIME_VERSION` defaults to the oldest runtime the current browser actually works against
   (v2.2.3 — displayxr-runtime#815, without which the browser cannot put the panel back into hardware
   2D); override with `-DMIN_RUNTIME_VERSION=…`, and bump it whenever a browser change starts
   depending on a newer runtime. A **display plug-in** (e.g. Leia) is the vendor's own installer — not
   bundled here.
3. **First-run capability notice (graceful fallback).** On install success it checks for a registered
   display processor + (if the runtime CLI is present) runs `displayxr-cli selftest`. If no DisplayXR 3D
   display is detected it shows a **one-time** notice — the browser still runs as an ordinary browser
   (the weave no-ops), and the preview/security disclaimer is repeated there. A registry marker prevents
   nagging twice.

## Build
```bash
# after scripts/build.sh has produced out/Official/chrome.exe:
BUILD_NUM=1 \
RUNTIME_SETUP="/abs/DisplayXRSetup-<ver>.exe"   # optional: bundle+chain the runtime
SIGN_CMD='<runner-local signer>'                 # optional: sign exe + uninstaller
installer/build_installer.sh
```
Output: `dist/DisplayXR-Browser-Preview-Setup-<ver>.<build>.exe`. To sign the finished installer via the
remote provider instead of a local `SIGN_CMD`, run `scripts/sign.sh dist` (folder-sign path).

## Verify (per reference_installer_verification)
Silent install + uninstall and inspect the result:
```bash
DisplayXR-Browser-Preview-Setup-*.exe /S        # then check %ProgramFiles%\DisplayXR\Browser\chrome.exe,
                                                #  HKLM\...\Uninstall\DisplayXR Browser, shortcuts
"%ProgramFiles%\DisplayXR\Browser\Uninstall.exe" /S   # then confirm the dir + reg keys are gone
```
First-run notice: install on a box with **no** DP registered → the one-time MessageBox fires; install
with the runtime + a DP → it stays silent and the weave is live.

Runtime version gate (#68): temporarily set `HKLM\Software\DisplayXR\Runtime\Version` to something
below `MIN_RUNTIME_VERSION` (or delete it) and re-run the installer — the detail log must say the
runtime is too old, and without a bundled `RUNTIME_SETUP` the warning MessageBox must fire. Under
`/S` **no** dialog may appear (both MessageBoxes are `IfSilent`-guarded; a modal in a silent install
hangs the whole chaining installer with nothing on screen to dismiss).

Iterating on the installer does **not** need a Chromium rebuild — point `-DSTAGE_DIR` at an existing
staged tree and call `makensis` directly (`C:\Program Files (x86)\NSIS\makensis.exe`, not on PATH),
omitting `-DSIGN_CMD` so each iteration skips two large signing uploads.
