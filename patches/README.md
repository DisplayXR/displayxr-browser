# Patch series — inline-3D over Chromium `151.0.7922.77`

`git format-patch --binary` of the `displayxr-inline-3d` fork over the pinned stable tag
`151.0.7922.77` (M151), as set in [`../scripts/config.env`](../scripts/config.env). **64 commits** (~30 files are the vendored OpenXR SDK; the real
integration surface is ~100 files — see [../docs/integration-points.md](../docs/integration-points.md)).
Patch 0064 makes **Phase 2 (occlusion)** real: the flag now composites the split. Four things go live
together, because none of them is correct alone. The difference clip is enabled (the one bool 0063
left false), so the page raster is punched out of the tile rects; `WeaveCompositedSurface`'s phase (B)
draws the published over-plane `kSrcOver` over the whole window right after the woven draw-back
(NEAREST, `kStrict`, inside the existing flush/submit bracket, with risk guard R7's size check
skipping rather than sampling a stale-sized plane), mirrored in the macOS branch and drawn LAST so it
wins; the v4 DP-composited overlay atlas is stood down in all three places and `display.cc` stops
suppressing the exclusion-overlay resources, because those two ARE the Phase-1 occlusion mechanism —
it can only lift content that DECLARED itself, the split lifts whatever the draw order says is over a
tile, and running both would composite the declared overlays twice while suppressing them under the
split would drop them entirely; and the GPU stage reads `--inline-3d-occlusion` itself, cached in the
`SkiaOutputSurfaceImplOnGpu` constructor exactly as `gpu_main.cc` reads the other inline-3D switches
(one switch, two readers — one thread punches the page, the other repairs it, so a split verdict would
be a hole). Nothing is deleted: the legacy path is dormant, not gone, so **both paths ship in one
binary** and the hardware A/B is a relaunch — `--inline-3d-occlusion` is the split, the default and
`--disable-inline-3d-occlusion` are Phase 1 byte for byte. What the A/B has to show: an UNDECLARED 2D
element over a tile rendering as crisp 2D over 3D with ZERO declarations (the whole point), a
translucent scrim blending once rather than double-darkening, scroll-glued overlays staying glued, and
the Phase-1 exclusion corpus unchanged-or-better. The per-pixel story inside a tile rect is now exact
rather than approximate: `output` holds page + under only (the clip removes the over content BEFORE
phase (A) snapshots it, which makes patch 0050's pre-blend backdrop the true backdrop — its comment now
says so), the woven draw covers the rect opaquely, and the plane composites 2D-over with the page's own
alpha. R9 is restated where it lives: the difference clip is the ONLY thing keeping translucent
above-content out of both the backdrop and the over-plane, and must never be weakened. Partial swap
needs no change — the composite is whole-window but reads a surface whose undamaged regions carry
identical pixels, the same contract the woven texture already relies on. Diagnostics: one throttled
`[DisplayXR] inline-3D occlusion composite:` marker with the plane size and drawn/skipped. Patch 0065
deletes the dormant legacy path and makes the split the default.
Patch 0063 opens **Phase 2 (occlusion)**: the page content sitting OVER a woven tile is lifted onto
its own transparent plane so the display processor can composite it above the weave, instead of the
page burying the tile. This patch builds the whole mechanism and deliberately connects none of it —
with `--inline-3d-occlusion` off (the default) nothing runs; with it on one extra transparent surface
is produced and ignored. Presented pixels are unchanged either way, which is the point: every
allocation, transform, clear and quad-replay path becomes observable on real hardware a patch before
it can break anything. The split is computed at DRAW time from the live root `quad_list` — never from
the aggregation-time quad ordinals, which `Display::RemoveOverdrawQuads()` and
`OverlayProcessor::ProcessForOverlays()` invalidate before anything is drawn. `QuadList` index 0 is
the FRONTMOST quad, so for a tile canvas quad at index `k` the OVER set is `[0, k)` and back-to-front
is descending index; `k` is found by canvas resource id with LAST match winning (the deepest
occurrence, hence the widest defensible over set), and a tile whose `k` cannot be found keeps
Phase-1 behaviour and says so in the log. Clip vectors are PER QUAD — a quad above tile A and below
tile B is clipped against A only. Excluded from the over set, each counted by reason: 3D sorting
contexts, non-`kSrcOver` blends, ALL `AggregatedRenderPassDrawQuad`s (pixel-moving filters exist, so
"it only wraps one pass" is false), `RequiresOverlay` quads, any tile's own canvas quad, and
resources already suppressed from the page draw. The plane is painted before the root pass so the GPU
task queue is strictly plane-then-page, with `is_overlay=false` keeping the weave guard inert for it.
The difference clip that would punch the page out of the tiles is fully plumbed but gated off by one
bool, which is what patch 0064 flips.
Patch 0062 extends **Phase 1 identity** to exclusion overlays (browser#18/#49). An exclusion is a
promise that an element's pixels stay 2D, out of the weave — and two channels describe those
exclusions: the legacy metadata list is COMPLETE (Blink walks the declaration list every frame) but
its geometry trails the impl scroll, while a draw-time tracked rect is EXACT but only best-effort
present, because arbitrary overlay DOM has no guaranteed paint chunk. 0049 could only CHOOSE between
them, wholesale per frame, so every exclusion whose element emitted no chunk that frame was silently
dropped — and its pixels then rode into the tile's SBS weave input and got woven (browser#22's
blown-up header). Carrying each exclusion's element token end to end lets the aggregator MERGE the
two instead: it enumerates the complete list and upgrades rows individually by id, so a tracked
entry's presence can never suppress another row and a row never mixes geometry bases. The
exclusion→quad join becomes `(namespace, layer id)` equality with best-overlap kept as a logged
fallback, diagnostics are throttled PER ID (a single global counter is what made the 0049 drop
invisible), the session de-duplicates an element excluded from several windows, and overlays are
finally composited in a real stacking order — back-to-front by root-pass quad ordinal, replacing a
geometric (y,x,w,h) sort that was never a z-order at all.
Patches 0059–0061 are **Phase 1 identity**: the weave stops guessing which quad draws an inline-3D
canvas and is told. 0059 carries the cc `LayerImpl` stable id onto every tracked element rect and
records the matching SharedQuadState id + client namespace on each root resource quad (inert
plumbing). 0060 makes the join possible at all — the tracked rect used to ride the element's
background paint chunk, which merges into the enclosing PictureLayer, while the canvas pixels are a
separate ForeignLayer, so the two could never share an id; `HTMLCanvasPainter` now registers the rect
on the layer holding the pixels, `ReplacedPainter` stops forcing the duplicate background chunk, and
the aggregator matches by `(namespace, layer id)` with the old best-overlap score kept as a logged
fallback. It also makes the element's token survive `XRDisplayLayer.close()` (derived from the
element, not minted per layer) so lazy re-activation does not orphan GPU state on every scroll.
0061 re-keys all per-target GPU weave state — provider slot, scratch image, in-flight submit rect —
by that token instead of by vector index, with a 30-frame absence grace period, a 32-target cap, and
a new single-target `PruneTarget()` on the weave provider.
Patches 0057–0058 kill the navigation ghost (browser#87), where the previous page's woven tiles
repainted over the page you navigated to: 0057 gates the Phase-B draw-back on at least one weave
submit having succeeded this frame (the shared woven texture is persistent, and the runtime only
clears its gaps when something is actually submitted), and 0058 clears the inline-3D rect state —
rects, exclusions, and the browser#83 scroll base — on session end *and* on navigation commit,
which nothing did before.
Patch 0054 makes the panel's hardware 2D/3D element follow the foreground window's active tab
(browser#55): the browser used only to go *quiet* when a page had no inline-3D content, and the
element is sticky, so the lens stayed on over flat pages. Needs displayxr-runtime#815 to take
effect — a weave present-owner cannot reach hardware 2D on runtime v2.2.2.
Patches 0043–0044 add overlay exclusion (browser#18): 2D overlays composited over the woven 3D
via isolated composited-layer resources (browser-side; no runtime change). Patch 0045 fixes the
two overlay/tile scroll bugs (browser#18): the overlay no longer lags the tile on scroll (aggregator
uses the compositor-exact quad rect, not the main-thread getBoundingClientRect), and 3D tiles no
longer squish at the top/bottom screen edges (the clean-canvas SBS is sub-regioned to the visible
fraction using the canvas layer's unclipped rect).

Apply with `git am --3way patches/*.patch` onto a fresh checkout of the tag (or just run
`scripts/build.sh`). Verified to reproduce the fork branch **exactly** (identical tree hash).

The series is roughly chronological by build phase (B2 browser-process weave client → B2c real-canvas
weave → B3 JS surface + head-tracked off-axis session → B4 chrome port + CEF sub-rect model → B4c retire
the launch flags → B4d GPU-resident zero-copy weave → batched submit + scene rig on `XR_DXR_view_rig`).
Patch 0040 delay-loads `openxr_loader.dll` so the sandboxed renderer survives in a
non-component/official build (displayxr-browser#15). On each monthly rebase this series is regenerated
against the new milestone tag (see [../docs/rebase-runbook.md](../docs/rebase-runbook.md) §4).
