# Remote build (free the local box)

The multi-hour Chromium compile can run on the remote **signing/build box** instead of a local
dev/display machine. This offloads the *compile*; the glasses-free **weave still has to be eyeballed on
a DisplayXR display box** afterward (the build box has no 3D display).

## How it fits the existing infra
Same box + pattern as release signing: the self-hosted Windows runner and toolchain live in the
provider repo named by **`$DXR_SIGN_REPO`** (from `displayxr-runtime/.env.local`, currently
`LeiaInc/codesign-runner`). That repo hosts the **`build-browser`** workflow (alongside
`build-signed-release.yml`); we dispatch it from here. The workflow is **PowerShell-only** because the
box has no bash/pwsh for Actions — it reuses this repo's *data* files (`patches/`,
`scripts/args.official.gn`, `branding/BRANDING`) but reimplements fetch/build/package/sign in
PowerShell. It signs in-place with the box-local `SIGN_CMD` (the build box *is* the signing box).

## Run it
```bash
scripts/remote-build.sh                 # build main, sign, upload the tree
scripts/remote-build.sh --installer     # also build the signed preview installer
scripts/remote-build.sh --tag 151.0.xxxx.yy --ref my-rebase-branch   # a rebase build
```
The script dispatches the workflow, watches it, and downloads `dist/DisplayXR-Browser/` (and the
installer with `--installer`). Then copy that tree to a DisplayXR display box and verify the weave per
[rebase-runbook.md](rebase-runbook.md) §6.

Or dispatch directly:
```bash
gh workflow run build-browser.yml -R "$DXR_SIGN_REPO" -f chromium_tag=150.0.7871.24 -f sign=true
```

## One-time box provisioning (heavy — the real prerequisite)
The build box needs, once:
- **~200 GB free disk** on the `CHROMIUM_ROOT` drive (`C:\cr` by default in the workflow).
- **depot_tools** (the workflow bootstraps it to `$DEPOT_TOOLS` if missing) + `DEPOT_TOOLS_WIN_TOOLCHAIN=0`.
- VS 2022 (C++ workload) + Windows SDK (the box already has these for component builds).
- The first run's `fetch chromium` is tens of GB + hours; later runs only `gclient sync` to the pin.

**Operational note:** this drops a ~150 GB Chromium tree on the *signing* box. If that box's role/disk
shouldn't carry Chromium, register a **separate** self-hosted runner (same `runs-on` label, or edit it)
and point the workflow's `CHROMIUM_ROOT` at that box. GitHub-*hosted* runners can't do this (4-core /
small-disk / 6 h cap, no RBE).

## What this does and doesn't buy
- ✅ Frees the local machine during the compile; good for the monthly rebase.
- ❌ Not faster per se — no RBE, so it still compiles at the box's core count.
- ❌ Doesn't remove the local **weave eyeball** on a DisplayXR display.
