# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repo is

A **Chromium fork** that adds glasses-free **inline-3D weave** for DisplayXR 3D displays: the
`inline-3d` WebXR session mode + `XRDisplayLayer` bound to a DOM element, woven GPU-resident in
the GPU process. Every other website renders as ordinary Chromium; on non-DisplayXR hardware the
weave silently no-ops.

**This repo holds no Chromium source.** It holds a **patch series** applied over a pinned upstream
milestone tag, plus the fetch/build/brand/package/sign/release lane.

- **`scripts/config.env` is the SINGLE source of truth for the pin** — currently
  `CHROMIUM_TAG=151.0.7922.77`. Bump it there and nowhere else. The patch count in `patches/`
  grows week to week (65 as of 2026-08-19) — count it, don't quote a doc.
- Applied with `git am --3way patches/*.patch` onto a fresh checkout of the tag (`scripts/build.sh`
  does this). The series is verified to reproduce the fork branch's tree hash **exactly**.
- Rebase cadence, conflict triage, and the mandatory weave verification: **`docs/rebase-runbook.md`**.
  The enumerated file set a conflict can land in: **`docs/integration-points.md`**.

## Patch-capture discipline (load-bearing)

**Never hand-edit a `.patch` file.** A patch is *captured output*, not source. Edit the Chromium
working tree, commit there, then regenerate — `docs/rebase-runbook.md` §4:

```bash
git format-patch --binary --no-signature -o "$REPO/patches" "$CHROMIUM_TAG"..displayxr-inline-3d
```

Then run the runbook's `GIT_INDEX_FILE` verify loop — it re-applies the series into a throwaway
index and asserts the resulting tree hash equals the branch's. A series that does not reproduce the
branch is broken even if every file "looks right". `--binary` is required: patch 0001 carries the
vendored OpenXR loader as binary hunks.

`scripts/aws/do_rebase.ps1` syncs `patches/` from **this repo** onto the build box, so whatever is
committed here is exactly what builds. `scripts/weave-gate.sh` derives the risk set from the patch
series (never from the prose in `integration-points.md`) to decide auto-publish vs human eyeball.

## Architecture map

```
Blink (JS surface)  ->  cc (rects on the commit)  ->  viz (aggregate + hook)  ->  weave backend
```

- **`components/displayxr/{common,browser,gpu}/`** — the shared weave component (all *new* files,
  never conflicts on rebase). `common/` = mojom; `browser/` = `DisplayXRWeaveClient` +
  service/weaver impls; `gpu/` = `DisplayXRWeaveGpu` (input staging + submit).
- **`components/viz/service/display_embedder/skia_output_surface_impl_on_gpu.{cc,h}` is THE hook
  point.** `WeaveCompositedSurface()` is the weave core; `MaybeWeaveRootRenderPass()` (DComp root
  pass) and `MaybeWeaveOutput()` (GL path) are its two entries. Most weave bugs are here.
- **`DisplayXRWeaveClient` is a platform dispatcher** (established by patch 0052): a stable facade
  over `SubmitBatchWin` / `SubmitBatchMac`, with backends in `displayxr_weave_client_mac.mm` /
  `displayxr_weave_gpu_mac.mm` (IOSurface+Metal vs DXGI+D3D11). **An Android backend is being added
  as the third arm of this same dispatcher** — mirror the `_mac` pattern, do not re-architect.
- **`ProduceOverlayForWeave`** (`gpu/command_buffer/service/shared_image/shared_image_manager.{cc,h}`
  + `shared_image_factory.{cc,h}`) = `ProduceOverlay` minus the SCANOUT gate; the only shared-image-
  layer surgery, and how the zero-copy path gets a raw platform texture out of a Viz SharedImage.
- **`content/gpu/gpu_main.cc`** — `PreSandboxStartup` creates the present-owner weave session inside
  the GPU process (patch 0023), so per-frame submit is a synchronous in-process call on Viz's present
  thread. The sandbox blocks *opening* the runtime pipe, not I/O on an already-open handle.
- Blink surface: `third_party/blink/renderer/modules/xr/xr_session.cc`, `xr_display_layer.{cc,h,idl}`
  — platform-neutral, and where `excludeElement` / `virtualDisplayHeight` live.

## Build

**Windows lane (the shipping product).** Bash scripts run in git-bash; every one sources
`config.env`. Checkout at `C:/cr/src`; build args in `scripts/args.official.gn`
(`is_official_build`, `is_component_build=false`, `target_cpu="x64"`).

```bash
scripts/fetch.sh    # sync a pristine Chromium checkout to $CHROMIUM_TAG
scripts/build.sh    # git am patches/* -> brand.sh -> gn gen -> autoninja chrome (multi-hour)
                    # then VERIFY THE WEAVE — rebase-runbook.md §6, MANDATORY
scripts/package.sh  # stage dist/DisplayXR-Browser/
scripts/sign.sh     # EV-sign via $DXR_SIGN_REPO (degrades to unsigned + warn)
installer/build_installer.sh   # NSIS (installer/DisplayXRBrowserInstaller.nsi)
scripts/release.sh  # publish as a preview GitHub Release
```

Branding is `branding/BRANDING` copied over `chrome/app/theme/chromium/BRANDING` by
`scripts/brand.sh`, plus `branding/initial_preferences` staged next to `chrome.exe` (seeds a NEW
profile only). CI drives the same lane on a self-hosted AWS box (`.github/workflows/build-box.yml`,
`pipeline.yml`).

**Android lane (being created).** `target_os="android"`, `chrome_public_apk`, built on an **EC2
Linux builder**. Its coordinates live in `.env.local` as `DXR_LINUX_BOX_*` and its key in
`.secrets/` — **both gitignored, never commit either.** The box is **STOPPED when idle and NEVER
terminated** (terminating loses the multi-hour Chromium checkout).

## Android port status

- Runtime contract: **`XR_DXR_weave` spec v7** + **`DXR_IPC_FD`** fd-adoption (browser-process Java
  connects, passes the socket fd over Mojo, GPU process adopts). Specs live in the
  **`displayxr-runtime` sibling repo** — read them there, don't infer from the Windows patches.
- Submit rides AHardwareBuffer handles (`xrWeaveSubmitHandlesDXR`); window geometry comes from the
  browser's Java UI (`xrWeaveBindWindow2DXR`). **HWND/DComp machinery does not port** — the mac
  backend already proved an identity window-snap is sufficient, so patches 0016/0017/0019/0024/0025
  have no Android counterpart.
- Test target: the **`displayxr-web` samples** (`samples/windows`). Device: **NP02J, serial
  `327343950099`**.

## Conventions

- DisplayXR-owned repo → **normal Claude co-author/session trailers are fine** (the no-trailer rule
  applies only to external/upstream repos like Khronos).
- **No vendor or customer names in public issues, PRs, or commits** — describe the configuration,
  not the partner.
- Rebase policy is a **~monthly Chrome stable-milestone** rebase, deliberately not mid-cycle security
  dot-releases (`docs/maintenance-policy.md`). Every rebase re-verifies the weave on hardware before
  it ships.
- Doc-only changes go straight to `main`; anything touching `patches/` or `scripts/` goes through a
  branch + PR.
- Kill `chrome.exe` before rebuilding (it locks the DLLs). **Never kill `displayxr-service`.**
