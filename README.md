# DisplayXR Browser

A **developer-preview**, Chromium-based browser that renders the whole web normally **and** weaves
glasses-free inline-3D for [`inline-3d` WebXR](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-displayxr-explainer.md)
pages on DisplayXR hardware. It is the productization of the **Step B** Chromium patch
(`displayxr-inline-3d`) from the [runtime roadmap](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-support.md).

> **This is a developer preview, not a maintained daily driver.** It is a demo / reference-implementation
> artifact with a **bounded** maintenance policy — see the packaging plan. Do not use it for sensitive
> browsing; use your primary browser for banking, etc.

## What it is

- It **is** Chromium — every website works. The only delta is the inline-3D surface: the `inline-3d`
  WebXR session mode + `XRDisplayLayer` bound to a DOM element, and the GPU-resident weave path.
- On a DisplayXR panel with the runtime + a display plug-in installed, inline-3D pages weave glasses-free
  3D at their element rect while the surrounding 2D page stays flat. On any other machine / a 2D monitor,
  the weave silently no-ops and it is an ordinary browser.
- Windows / D3D11 + DirectComposition only (that is where the weave path lives today).

## Relationship to other repos

| Repo | Role |
|---|---|
| [`displayxr-runtime`](https://github.com/DisplayXR/displayxr-runtime) | The OpenXR runtime + the Step-B patch **design/spec** (`docs/roadmap/webxr-step-b-design.md` §13, `displayxr-browser-preview.md`). The actual Chromium patch is validated against this runtime + a display plug-in. |
| **`displayxr-browser`** (this repo) | The fork productization: the inline-3D patch as a rebaseable series over a pinned Chromium milestone, plus fetch/build/brand/package/sign scripts and release automation. |
| [`displayxr-web`](https://github.com/DisplayXR/displayxr-web) | Inline-3D **web samples** + optional JS helper (the analog of `immersive-web/webxr-samples`). The three.js demo the browser navigates to. |
| [`displayxr-cef-host`](https://github.com/DisplayXR/displayxr-cef-host) | Step-A native OSR stand-in — a *different* artifact; not the browser product. |

## Status

**Shipping as a developer preview.** The patch series lives here (`patches/`, applied by
`scripts/build.sh`), CI builds it on a self-hosted box, and signed installers ship from
[Releases](https://github.com/DisplayXR/displayxr-browser/releases).

| | |
|---|---|
| Latest preview | [**0.1.11**](https://github.com/DisplayXR/displayxr-browser/releases/latest) — occlusion by draw order |
| Chromium pin | **151.0.7922.77** (stable) — `scripts/config.env` |
| Patch series | 71 patches over the pinned tag, ~100 files of real integration surface |
| Platform | Windows — D3D11 + DirectComposition |
| Requires | DisplayXR runtime **v2.2.3+** (the installer enforces it); **v2.7.2+ strongly recommended** (scroll-trail + service-restart fixes) + a display plug-in for the glasses-free effect |
| Update path | Version check against the feed at [`updates.displayxr.org`](https://updates.displayxr.org) — no silent auto-update |

Recent releases: **0.1.9** — scroll-sync + navigation-ghost fixes. **0.1.10** — element identity
end-to-end. **0.1.11** — occlusion by draw order: any 2D content over woven tiles now composites
correctly, per-pixel, automatically (the exclusion APIs are deprecated no-ops). Full notes on the
[Releases](https://github.com/DisplayXR/displayxr-browser/releases) page.

What works today: the `inline-3d` WebXR session mode and its JS surface, GPU-resident zero-copy weave
in the GPU process, batched per-frame submission of every visible element, per-element weave with
2D DOM overlays composited over the woven tiles, phase lock under scroll / zoom / window drag, and the
panel's hardware 2D/3D element following the foreground tab.

A weave can still miss on any given frame — the runtime's weave-input acquire runs on a deliberately
tight budget, and a heavy WebGL scene tile is the producer most likely to still be mid-write when the
service reaches for it. The browser now **degrades rather than blanks** when that happens. A tile's
canvas quad is withheld from the page raster on the compositor thread, before the weave outcome can
be known, so a missed weave used to draw the tile from neither side and flash it black
([#99](https://github.com/DisplayXR/displayxr-browser/issues/99)). On such a frame the GPU thread now
paints the tile itself from the resource it already holds, as a flat mono frame — the same fallback
the SDK shows when 3D is unavailable — and is invisible at frame rate.

Startup can also race the runtime's service. If `displayxr-service` happens to be restarting when the
browser negotiates, the weave client used to be stuck with whatever it got for the rest of the browser
session: in the GPU process, where the session is created once before the sandbox closes and can never
be created again, that quietly demoted every page to a one-rect-per-call submit path
([#92](https://github.com/DisplayXR/displayxr-browser/issues/92)) — the shape behind the scroll trails
and the predictor stalls; in the browser process it left inline-3D scenes **mono** forever, because the
view-rig extensions had been dropped to save the weave and nothing ever asked again. Neither sticks now.
A transient failure is retried rather than latched, the batched submit shape is a function of the
negotiated weave-extension version and nothing else, and a client that did come up without the rig
climbs back to a full session on a bounded backoff (seconds, then minutes) — while a runtime that
genuinely does not have those extensions is detected once and left alone. Grep `[DisplayXR][weave-mode]`
in the browser log for which mode a session is in and when it recovered.

The design and rationale live in the runtime repo:
[`webxr-support.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-support.md)
(Step B) and
[`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md)
(packaging). Original tracking issue:
[displayxr-runtime#733](https://github.com/DisplayXR/displayxr-runtime/issues/733).

## Try it

1. Install the [DisplayXR runtime](https://github.com/DisplayXR/displayxr-runtime/releases) (v2.2.3+
   minimum; v2.7.2+ strongly recommended) and, on Leia hardware, the
   [Leia SR plug-in](https://github.com/DisplayXR/displayxr-leia-plugin/releases).
2. Install [`DisplayXR-Browser-Preview-Setup-*.exe`](https://github.com/DisplayXR/displayxr-browser/releases/latest).
3. Open the live samples — <https://displayxr.github.io/displayxr-web/> — which is also the browser's
   default start page. In any other browser those pages render as ordinary 2D.

To author your own inline-3D pages, see [`displayxr-web`](https://github.com/DisplayXR/displayxr-web)
and the [`@displayxr/inline3d`](https://www.npmjs.com/package/@displayxr/inline3d) SDK.

## Layout

```
patches/     the inline-3D patch series over the pinned Chromium milestone tag
scripts/     config.env (the pin) + fetch / build / brand / package / sign / release
branding/    product name, icons, about-page, user-agent strings
installer/   NSIS installer (chains the runtime version check)
feed/        the update feed published at updates.displayxr.org
docs/        maintenance policy, rebase runbook, integration-point file list
diagnostics/ the weave-capture harness used to debug the pipeline on hardware
```

## Build

```bash
scripts/fetch.sh      # provision / sync a Chromium checkout to $CHROMIUM_TAG
scripts/build.sh      # git am patches/* onto the tag -> brand -> official static build
                      # (verify the weave here — rebase-runbook.md §6)
scripts/package.sh    # stage the runnable tree into dist/DisplayXR-Browser/
scripts/sign.sh       # EV-sign the staged tree
installer/build_installer.sh   # NSIS installer
scripts/release.sh    # publish the signed installer as a GitHub Release
```

The first official static build is multi-hour.

The pinned tag lives in [`scripts/config.env`](scripts/config.env); bump it there on each rebase.
Full monthly rebase procedure — fetch → apply → resolve drift → build → **verify weave** → sign →
release — is in [`docs/rebase-runbook.md`](docs/rebase-runbook.md). CI runs the same lane
(`.github/workflows/pipeline.yml`) on a self-hosted build box.

## Maintenance & security

Rebased ~monthly onto Chrome **stable milestones** — deliberately **not** onto Chrome's mid-cycle
security dot-releases, so the build is always some days-to-weeks behind on security fixes. That is the
bounded commitment that keeps this a demo/reference artifact rather than a browser-vendor obligation.
It renders the whole web normally and *functionally* could be a daily driver; the preview label is
about the **maintenance commitment**, not missing capability. Full policy:
[`docs/maintenance-policy.md`](docs/maintenance-policy.md).
