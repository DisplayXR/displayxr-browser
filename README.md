# DisplayXR Browser

A **developer-preview**, Chromium-based browser that renders the whole web normally **and** weaves
glasses-free inline-3D for [`inline-3d` WebXR](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-displayxr-explainer.md)
pages on DisplayXR hardware. It is the productization of the **Step B** Chromium patch
(`displayxr-inline-3d`) from the [runtime roadmap](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-support.md).

> **This is a developer preview, not a maintained daily driver.** It is a demo / reference-implementation
> artifact with a **bounded** maintenance policy — see the packaging plan. Do not use it for sensitive
> browsing; use your primary browser for banking, etc.

## Where the source lives

**This repo holds releases and issues, not source.** As of 2026-09, the Chromium patch series,
build lanes and release automation live in a **private** repo; this public one receives the
published builds.

That is the same split the DisplayXR shell uses, and it is about contribution economics rather
than secrecy: building this fork needs a multi-hour compile on a dedicated box, `depot_tools`,
and a 100+ patch series rebased onto Chromium roughly monthly. Over its life this repo saw no
external pull requests. The neutral-infrastructure argument for openness applies to the
**runtime** — which is the thing vendors and OEMs integrate against, and which stays public and
takes outside contributions — and does not transfer to a browser build.

**This repo keeps its name deliberately.** `versions.json[browser]`, the Android install
tooling and install instructions already sent to testers all resolve assets against
`DisplayXR/displayxr-browser`, so nothing user-facing moved.

What you can still do here:
- **Download builds** — see [Releases](https://github.com/DisplayXR/displayxr-browser/releases).
- **Report a bug** — issues are open and read.
- **Read the maintenance policy** — [`docs/maintenance-policy.md`](docs/maintenance-policy.md),
  which the release notes link to.
- **Understand the split** — [`docs/repo-split-plan.md`](docs/repo-split-plan.md).

Auto-update: shipped browsers poll the feed served from `feed/` at `updates.displayxr.org`;
that is still published from this repo.

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
| **`displayxr-browser`** (this repo) | **Releases, assets and user-facing issues.** The source moved to a private repo — see below. |
| [`displayxr-web`](https://github.com/DisplayXR/displayxr-web) | Inline-3D **web samples** + optional JS helper (the analog of `immersive-web/webxr-samples`). The three.js demo the browser navigates to. |
| [`displayxr-cef-host`](https://github.com/DisplayXR/displayxr-cef-host) | Step-A native OSR stand-in — a *different* artifact; not the browser product. |

## Status

**Shipping as a developer preview.** The patch series is built on a self-hosted box from the
private source repo; signed installers and Android APKs ship from
[Releases](https://github.com/DisplayXR/displayxr-browser/releases) here.

| | |
|---|---|
| Latest preview | [see Releases](https://github.com/DisplayXR/displayxr-browser/releases/latest) |
| Chromium pin | **151.0.7922.174** (stable) |
| Patch series | ~120 patches over the pinned tag (private repo) |
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

The third way a tile could go dark had nothing to do with the weave at all — the page was told,
for one frame, that it had no 3D to render ([displayxr-web#12](https://github.com/DisplayXR/displayxr-web/issues/12)).
The runtime builds the two off-axis eye views for a scene element on demand, and declines when the head
tracker has no fresh sample for that instant — correct, since inventing eye positions would be worse. But
the session consumed that answer on every animation frame and overwrote its views with it, so a single
declined locate collapsed `getViewerPose()` to one mono view, the scene drew one eye's worth of content
into a side-by-side canvas, and the tile blinked. Under GPU load the declines cluster, which is exactly
when it was reported. The last good views are now **latched** across a short run of misses (~0.5 s)
before the session concedes to mono; the cost is half a second of slightly stale head parallax in the
rare case the rig really has gone, which nobody can see. Changes that genuinely end the rig — session
end, the last scene element closing — still drop to mono at once. A gallery that recycles tile layers as
you scroll no longer loses the scene role along with the recycled tile, either. Because the latch makes
the misses invisible, the producer now counts them by reason: grep `inline3d rig miss` for the rates, and
`head tracking starving under load` for the one warning that says the latch is what is holding a scene
together.

The fourth way — and the **root** one, the case that survived all three fixes above — was that a tile
could be woven **from the hole the browser had just punched in the page**. To weave an element, the
compositor withholds its canvas quad from the page raster, because the woven pixels are drawn back over
that spot a moment later; the weave stage is separately handed the list of canvas resources it may
sample from. Those two lists were built from the same frame but were **not the same set**: the second
silently dropped any canvas whose resource had not resolved, while the first dropped nothing. A tile in
that gap was removed from the page and never offered to the weave — so the weave stage, finding no
resource for it, fell back to sampling the composited page **at the tile's rectangle**, which was by then
the empty hole. It wove the hole, the submit succeeded, and every counter in the system reported a
healthy frame while the tile went dark. It also explained the strangest symptom in the report: the weave
input is not cleared between frames, so consecutive captures of a blink came out byte-for-byte identical
and looked like a stale frame rather than a fresh mistake. The rule now is **never punch a hole you
cannot fill** — resolve first, withhold only what resolved, so a tile whose resource has gone simply
stays an ordinary page element for that frame. The weave stage additionally refuses, at every entry
point, to sample the page where the page may be holed; a tile that reaches neither route is repainted
flat from its own resource, per tile rather than only when the whole frame missed. And because every
step of this mechanism was silent — including a lookup whose failure was logged nowhere at all — the
whole path is now counted at error level: grep `[DisplayXR] weave tile skipped`, `canvas resolve
dropped`, `ZERO copies this frame`, and `inline-3D recovery draw`.

The fifth and last way is the only one that is not a logic error: **under heavy GPU load the browser
sometimes simply cannot read a tile's canvas in time.** With the four fixes above running on real
hardware, a page carrying two 3D elements — one a model, one a model plus a gaussian splat — showed the
light element rock steady and the heavy one blinking, at a rate that tracked how much work its producer
was doing. That is the signature of a lost race, not of anything being broken: to build the weave input
the compositor has to take read access to the canvas the page is still drawing into, and the heavier the
producer, the more often it is still holding that canvas when the compositor asks. Every safety net
built above then failed for the *same* reason a few microseconds later — the flat repaint of last
resort opens the very same resource — so the tile fell all the way through to the empty hole and the
counters, being shared, could not say which step had lost. Three changes. The compositor **asks twice**
before giving up, which usually wins because the producer has let go by the second ask. When the failure
happens *after* the tile's pixels have been assembled but before they reach the hardware weave path, it
now **reads them back from the tile's own copy** instead of from the page — that copy is hole-free by
construction, so the "never sample a holed page" rule has nothing to refuse. And when a tile really
cannot be produced at all, it is **no longer blanked: it keeps the frame it already had.** The weave
input is one window-sized surface that is never cleared, so a tile that cannot be redrawn this frame
simply is not overwritten, and re-submitting its unchanged rectangle re-weaves the pixels already
sitting there. A tile whose producer is starved for a long stretch therefore looks *slowed*, not black,
and only ever at its own rectangle: the moment it moves, the licence to keep it lapses. That also
retires the worst symptom in the whole report — when every tile declined there was no submit at all, and
the weave went quiet for seconds with nothing in either log; a kept tile still submits, so the pipeline
never stops. Every failure candidate on this path is now counted separately and **per tile**, which is
what makes "the heavy one fails and the light one does not" a measurement rather than an impression.

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
feed/        the update feed published at updates.displayxr.org
docs/        maintenance policy + the repo-split rationale
```

The patch series, build/brand/package/sign scripts, installer, branding and diagnostics
harness moved to the private source repo with the 2026-09 split.

## Building it

Not from this repo — the sources moved (see *Where the source lives*). Builds are produced by
CI on a self-hosted box and published here as releases.

If you need a build that does not exist yet, or hit something only reproducible from source,
open an issue rather than trying to reconstruct the series: it is a 100+ patch stack over a
pinned Chromium milestone and a multi-hour official static build.

## Maintenance & security

Rebased ~monthly onto Chrome **stable milestones** — deliberately **not** onto Chrome's mid-cycle
security dot-releases, so the build is always some days-to-weeks behind on security fixes. That is the
bounded commitment that keeps this a demo/reference artifact rather than a browser-vendor obligation.
It renders the whole web normally and *functionally* could be a daily driver; the preview label is
about the **maintenance commitment**, not missing capability. Full policy:
[`docs/maintenance-policy.md`](docs/maintenance-policy.md).
