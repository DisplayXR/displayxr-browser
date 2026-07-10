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

**Planning / scaffolding.** No build yet. The working patch currently lives on branch
`displayxr-inline-3d` in a local Chromium checkout; capturing it here (P1) follows the P0 official-build
spike. Tracking issue: [displayxr-runtime#733](https://github.com/DisplayXR/displayxr-runtime/issues/733).

## Planned layout

```
patches/     the inline-3D patch as a .patch series over the pinned Chromium milestone tag
scripts/     fetch (depot_tools + checkout) / build (official static) / brand / package / sign
branding/    product name, icons, about-page, user-agent strings
docs/        maintenance policy, rebase runbook, integration-point file list
```

## Build (planned — see the packaging plan)

Phased: **P0** official-build + rebrand spike (gate) → **P1** patch series + scripts here → **P2** signed
installer chaining the runtime + display plug-in → **P3** GitHub Release + download → maintenance policy.
Full plan: [`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md).
