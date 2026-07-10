# Installer — `DisplayXR-Browser-Preview-Setup.exe`

A signed NSIS installer for the DisplayXR Browser developer preview. Reuses the runtime installer's
patterns (two-pass signed uninstaller, 64-bit registry view, ARP entry).

## What it does
1. **Installs the browser** (the staged static Chromium tree from `scripts/package.sh`) into
   `%ProgramFiles%\DisplayXR\Browser`, with Start-menu + desktop shortcuts and an Add/Remove entry.
2. **Chains-or-requires the runtime.** The DisplayXR runtime + a display plug-in are the weave
   prerequisites. If a runtime is already installed (`HKLM\Software\DisplayXR\Runtime\InstallPath`) it's
   left alone; if not, and a runtime setup is bundled (`-DRUNTIME_SETUP=…`), it's chained silently
   (`/S /NOSTART`, like the meta-bundle). A **display plug-in** (e.g. Leia) is the vendor's own
   installer — not bundled here.
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
