# Patch series — inline-3D over Chromium `151.0.7922.77`

`git format-patch --binary` of the `displayxr-inline-3d` fork over the pinned stable tag
`151.0.7922.77` (M151), as set in [`../scripts/config.env`](../scripts/config.env). **108 commits** (~30 files are the vendored OpenXR SDK; the real
integration surface is ~100 files — see [../docs/integration-points.md](../docs/integration-points.md)).

**Numbering note:** the series runs 0001–0106 then **0111** and **0112** — 0107–0110 are reserved by the
shared viz tail (browser#141), open alongside this one. 0111 (browser#130, Windows/macOS/Android
alike) takes the first free slot above it, so it is this patch's final number whether or not that
PR lands, and nothing renumbers twice. `git am patches/*.patch` is unaffected: it applies in
filename order and a gap is not a conflict.

Patch **0112** closes browser#119 + browser#120 (Windows). The browser#99/web#12 recovery draw was
sourcing from the producer's LIVE canvas SharedImage, which `D3DImageBacking::ValidateBeginAccess`
refuses for as long as a write access is open — so it read `n=0` on every healthy frame. 0112 sources
the mono draw from the **per-target weave scratch** instead (the one the fork itself composes and is the
sole writer of), which makes `recovery_source_actually_available(tile)` answerable without probing a
contended resource. It also gives browser#120's frosted regions their mono content **in the page raster,
before the backdrop-filter pass samples it** (the ordering is the whole fix — repairing after the glass
is composited would destroy the crispness D' exists to protect), and decouples the Phase-2 over-plane
composite from the weave-landed gate, a latent 0057/0064 coupling that dropped the 2D repair on any
frame the weave missed. **Numbering note:** 0112 collides with the open Android series (browser#138,
patches 0103–0110) and with browser#139's 0111; renumber on merge — whichever lands second moves.

**Patches 0083–0106 are the ANDROID arm** (browser#100, design in
[../docs/android-port.md](../docs/android-port.md), device traps in
[../docs/android-pitfalls.md](../docs/android-pitfalls.md)). Everything before 0083 is
Windows + macOS and is unchanged by them: the Android arm is additive, entering through the
same `DisplayXRWeaveClient` / `viz::DisplayXRWeaveProvider` platform dispatcher patch **0052**
introduced for macOS, plus one `#if !BUILDFLAG(IS_ANDROID)` arm inside 0074's clean-scratch CPU
fallback (Android has no CPU-readback leg to fall back to). The shape of the arm: the browser
process connects to the runtime and ships the socket down (0084–0085, runtime
`android-ipc-fd-adoption`), the GPU process owns the present-owner session and submits
AHardwareBuffers (0088–0089), and the pixels move by Skia-drawing each element straight into ONE
shared window-sized staging image at its window position — there is no per-target scratch and no
provider-side blit, which is why the destination/offset abstraction in 0089 exists. The rest are
the Android analogues of already-landed Windows behaviour: rig locate (0092–0093), flat regions
and frosted-glass clip (0097–0098), the v4 overlay atlas (0099), and the draw-back (0095, 0101).
Building this arm is `autoninja -C out/Android chrome_public_apk`; it needs the DisplayXR Android
runtime installed on the device, and the sim-display fallback is silent, so verify the active
plug-in after any runtime install.

**Patches 0103–0106 are the occlusion/space follow-up** (browser#100) that made
`displayxr-web` `samples/composition` cases 01/09/13 show their 2D and 3D content together on
device. 0103 scopes the woven draw-back to the rects the runtime actually wove (the companion
half of 0102's SurfaceControl evaluation-site gate); 0105 appends `--inline-3d-occlusion` by
default on Android exactly as the `IS_WIN` block in `chrome_main_delegate.cc` already did, and
0106 hoists the Android over-plane occlusion composite out from behind the five weave
preconditions so it also runs on weave-less frames. 0104 is the `[DXR-SPACE]` diagnostic
(draw-back geometry printed as numbers) and is **temporary** — drop it once the scroll-lag item
is closed. All four are Android-only: they touch no shared behaviour the Windows lane relies on.

Patch 0111 makes the weave honour the **ancestor clip chain** (browser#130). A tile inside an
`overflow:auto` panel, scrolled out of view within the panel, came back woven OUTSIDE the panel
as soon as the PAGE scrolled — the browser#117/0081 corruption class, the weave painting a region
the page does not own. The governing invariant is that a weave rect is the element's screen rect
intersected with every ancestor clip. Two different notions of "clipped" meet here and only one of
them is being added: cc deliberately SKIPS the `visible_layer_rect` intersection for
`kInline3dWeave` (0026 — the tracked chunk lands on a layer with no drawable content, so that rect
is empty and would zero the weave; 0079/0080–0082 then rely on the resulting raw bounds so a tile
partly visible at the VIEWPORT edge still scores a geometric join), while the property-tree CLIP
CHAIN is a live quantity that is correct for a non-drawing layer and was simply never applied.
0111 walks it with cc's own `PointIsClippedByAncestorClipNode()` idiom, stopping ABOVE the viewport
clip node so the viewport edge stays browser#117's case and an element with no clipping ancestor is
byte-identical to before. The viz half is the other necessary edge: an empty tracked rect is no
longer dropped by the aggregator, because after 0094 dropping it lowers the tracked cardinality, the
per-element legacy fallback reads the element as MISSING, and Blink's UNCLIPPED
`getBoundingClientRect` rect is admitted in its place — resurrecting the tile the panel just clipped
away. Kept on the list it takes the path an off-window tile already takes (0028: window-bounds
intersect empty → clear pending/drawn, submit nothing, keep the slot and its scratch images).
Patch 0069 stops **browser-UI popups ghosting** (browser#88, Phase 3 Stage 4 item B). The omnibox
dropdown, the autofill popups and every menu are separate OWNED top-level HWNDs that DWM composites
ABOVE the browser window: they never enter Viz and can never be woven, yet the panel underneath stays
physically 3D, so their perfectly flat pixels are viewed through a lenticular they did not ask for and
read soft and ghosted. (`ui/views/controls/menu/menu_host.cc` sets `force_software_compositing = true`
on Windows for menus — there is no Viz frame to weave, by construction.) 0067's flat-regions channel
cannot reach this case because it rides the weave SUBMIT: the failing scenario is an inline-3D page
sitting IDLE — no damage, no Viz frame, no submit at all — when the user clicks the omnibox, so a
submit-chained wish would never republish and the popup would ghost for as long as it stayed open.
This therefore uses v8's OTHER half, the STICKY `xrWeaveSetScreenFlatRegionsDXR`, which the runtime
applies on the spot (it re-rasters and republishes the wish inside the call, no submit needed). The
popups are enumerated GENERICALLY rather than by special-casing the three types that motivated the
bug: `aura::EnvObserver::OnHostInitialized` is the universal "a new top-level HWND exists" edge and
`views::Widget::GetAllOwnedWidgets()` on each browser window's native view says what those HWNDs
actually are — on Windows that walks the HWND OWNER relation, which is *the same relation DWM
composites above the owner*, so the enumeration and the visual problem share one definition; each
enumerated popup then carries a `WidgetObserver` for its own moves, shows and destruction. Tooltips,
bubbles, extension popups and anything future fall out for free. What is deliberately NOT done is
suppressing the weave beneath a popup: subtracting those rects from the weave rects, or skipping the
draw-back there, would show raw unwoven page through a `kTranslucent` popup's shadow and rounded
corners — the ghost is a LENS artefact, not a compositing one, so switching the panel's 3D element off
over the region *is* the whole fix, and there is a comment saying so because it looks like an
optimization someone will want to make. Transport extends the EXISTING browser→GPU
`DisplayXRDisplayMode` interface with `SetPopupOccluders` rather than adding a fifth, keeping both
messages ordered on one pipe and the display-mode controller the single owner of it; the browser owns
policy (which HWNDs, when, debounced **16 ms** — an order of magnitude tighter than the controller's
300 ms, because that timer guards a hardware transition of the whole panel while this one only moves a
lens hint over already-correct pixels and popup open/close has to feel instant) and the weave client
owns the wire (spec-v8 gate, clamp to 8, idempotence — the runtime's immediate re-raster is a
`ClearView` plus a vtable call under its `render_mutex`, so a redundant call is not free). The wish
comes from the controller rather than a second copy of the foreground policy, pushed from `Apply()`
BEFORE its early returns, which fire when the panel needs no change and say nothing about whether the
latch does. Leak safety is the one failure mode here that is visible rather than merely absent — a
leaked rect is a permanent flat band over live 3D — so the set is full-every-time and never a delta,
recomputed from scratch on every event, sent as `{}` when inline-3D demand goes false, cleared on
shutdown, and re-asserted after a GPU crash (a fresh session latches nothing, so the reconnect is
modelled as an EMPTY latch rather than an unknown one, which also keeps a browser with no popups open
from binding the pipe at all). Past the 8-rect cap the smallest are DROPPED, never merged — a dropped
popup keeps ghosting, whereas a bounding box would switch the lens off across the working 3D between
two popups — the same bias rule as 0067, with a positional tie-break added so which rect loses does
not depend on the allocator. Windows only, and against a pre-v8 runtime the entry point does not
resolve and the entire path is inert.
Patch 0068 is **D′ — frosted glass** (browser#88, Phase 3 Stage 3), and it closes the worst cell of the
occlusion matrix. An excluded render pass carrying a BACKDROP FILTER over a woven tile used to lose
outright: it cannot join the Phase-2 over-plane (a backdrop filter samples a backdrop that plane does
not have) and it cannot stay under the weave (the woven tile is drawn back opaquely), so a frosted card
over an inline-3D element simply disappeared behind it. D′ is one decision with three coupled effects,
all driven from a single recording in the split pass: the woven draw-back is CLIPPED OUT of the
element's rect (`SkClipOp::kDifference`, so `output`'s own crisp page-drawn glass shows through); the
same rect JOINS 0067's flat list, so a capable panel switches its 3D element off there and the region
does not ghost either; and what is lost is DEPTH BEHIND IT, because the page drew that blur against the
flat page backdrop — at page-draw time the woven pixels did not exist. That is strictly better than
both alternatives (element invisible, or element smeared through the interlace lattice), and it is why
the wish's usual "never flatten working 3D" guard does not apply to these rects: the clip already
removed the 3D from under them. The two halves must therefore never be separated — a frosted rect in
the flat list that was NOT punched out of the draw-back would switch the lens off over live woven
pixels — and they cannot be, because both come from the same draw-time pass (risk guard R12) and
travel on the same GPU task. Two details are load-bearing. The clip uses the quad's OWN
mapped+clipped rect, not the influence rect the split already had (they differ only for an RPDQ, whose
rect is expanded by `GetExpandedRectForPixelMovingFilters`): punching out a blur's REACH would leave a
halo where the weave is gone and the page has nothing to show. And the clip is NOT anti-aliased — an
AA edge would blend woven and page pixels in a one-pixel seam, and blending into woven pixels breaks
the interlace lattice, the same reason the draw itself samples NEAREST. The frosted rects are not
capped (the wire cap bounds the wish only; dropping a clip would resurrect the vanishing-element bug)
but they ARE counted in the flat list's `raw/sent/dropped` accounting, and the plane-split marker
gains `frosted=N`. Frame-scoped and single-use like the flat list, and drained before phase (B)'s early
returns: a stale flat rect only ghosts, a stale CLIP punches raw page through a live weave. Windows
only — the macOS synchronous draw-back still draws the whole window, so frosted elements keep their
pre-Stage-3 behaviour there.
Patch 0067 is the **browser half of the per-region hardware wish** (browser#88, Phase 3 Stage 2); the
runtime half shipped as `XR_DXR_weave` spec **v8** (displayxr-runtime#1065). Until v8 the weave path
drove the panel's physical 3D element all-or-nothing: one woven element held the WHOLE panel behind
the lens, so the flat 2D around and over it was viewed through a lenticular it did not want — the
ghosting the browser ships today. v8 lets the caller name the flat regions and the runtime derives
`wish = union(submitted weave rects) − union(flat rects)`, publishing it to the display processor,
which switches its 3D element per region where the hardware can (ADR-027 Decision 5). The flat list
comes from nowhere new: the Phase-2 draw-order split already knows which page quads were lifted OVER a
tile, so `ComputeInline3dPlaneSplit` now emits, from the SAME admissions that fill
`inline3d_over_clips_`, the intersection of each admitted quad's rect with the tile it covers — one
pass, two lists, no second coordinate derivation to drift. Two rules are the whole patch. **Opaque
only** (a tightening over the design sketch): the over set admits translucent `kSrcOver` content too —
a scrim, a fade, a rounded-corner mask — and there the woven 3D still shows THROUGH the 2D, so calling
it flat would switch the lens off over working 3D content, the one failure this feature must never
cause; the producer gates on `DrawQuad::ShouldDrawWithBlending()`, which covers every way a quad can
be non-opaque over the tile, and a translucent quad simply leaves its area 3D. **Drop, never merge**:
over the wire cap of 16 (`XR_WEAVE_SUBMIT_MAX_FLAT_RECTS_DXR`) the list is reduced by
strict-containment dedupe (lossless) then largest-area-first truncation, DISCARDING the smallest —
bounding-box merging is never done, not even for rects that look adjacent, because a flat rect that
GREW flattens working 3D (a mono regression) whereas a MISSING one leaves that area 3D (the
already-shipped ghosting), and the plane-split marker now reports
`flat{raw/sent/dropped/translucent}` so a drop is visible rather than silent. The list rides
`SetInline3dOverPlane` — the same GPU task as the plane it describes, so the atomicity the wish depends
on is the FIFO queue's, not a second sync — is DRAINED at the batch (single use, so an error path that
skips a publish cannot re-send a stale wish against a later frame's rects), and reaches the runtime
through a new `DisplayXRWeaveProvider::SetBatchWish`, deliberately NOT `SetBatchOverlay`: that channel
is reserved for handing the DP an over-plane to composite and it moves PIXELS, whereas this one moves
only the hardware element. The client chains `XrWeaveSubmitFlatRegionsDXR` on the LAST batch chunk (the
v4 overlay precedent — one whole-window statement, landing once after every rect has woven), spliced
ahead of whatever is already chained so it composes with the overlay chain rather than replacing it,
and gated on the runtime's reported `weave_spec_version >= 8`. The gate is deliberate even though a
pre-v8 runtime would skip an unknown chained struct anyway: the browser does not get to assume every
shipped runtime walks unknown chains politely, so the gate makes the pre-v8 wire byte-IDENTICAL rather
than merely probably-ignored. Empty list, pre-v8 runtime, macOS, or a DP with no per-region capability
all reduce to exactly today's behaviour — the wish is advisory in the ADR-027 Decision 6 / ADR-030
sense: it moves the hardware element and nothing else, and the woven pixels are bit-identical with and
without it. The vendored `XR_DXR_weave.h` is re-synced from the runtime canonical at spec v8; v7 and v8
are purely ADDITIVE over the v6 copy it replaced (verified: no existing `XrStructureType` value, struct
layout or entry point changed), so `Local modifications: none` stays true.
Patch 0066 is **Phase 3 Stage 0** (browser#90): two defects that left the display-mode policy latched
at the wrong answer across a navigation, both browser-side only — nothing in the runtime or the
extension wire protocol moves. C-1, the reported bug: navigating away from a 3D page left the panel in
3D, because a document in the back/forward cache keeps its `DisplayXRService` pipe (so its demand is
never retracted) and renderer-side retraction is not even available once the execution context is
destroyed. `ComputeWish()` already discounted it, but nothing on a same-tab navigation ever asked — the
controller woke only on demand events and browser create/close/activate/deactivate/active-tab-change.
The fix is a `WebContentsObserver` on each window's active tab overriding `PrimaryPageChanged()` to
`ScheduleApply()`: it fires on cross-document commits, bfcache restores and prerender activations, and
deliberately not on same-document navigations, which a live inline-3D session is expected to survive.
C-2 is a latent permanent-stuck-2D race, fixed here because C-1's fix makes navigation a hot path: on
a same-RFH cross-document navigation the new document binds a fresh pipe with the SAME
`GlobalRenderFrameHostId`, and the old pipe's destructor retraction is unordered against the new pipe's
first `SetInline3DDemand(true)` — if the retraction lands second it erases the NEW document's claim,
and since the renderer is edge-triggered it never re-reports. A generation token fixes it:
`DisplayXRServiceImpl` mints an `instance_id_` from a process-global counter, `demanding_frames_`
becomes id → generation, a demand is newest-claimant-wins, and a retraction erases only when the
stored generation matches — a stale retraction is dropped instead of clearing a live claim.
Patch 0065 makes the split the DEFAULT and deletes the mechanism it replaced. The 0064 A/B passed on
real hardware — per-pixel occlusion of content that declared nothing, the DP overlay atlas confirmed
dormant, translucent chrome over the weave verified by eye — so `chrome_main_delegate.cc` now appends
`--inline-3d-occlusion` by default alongside `enable-inline-3d` and `inline-3d-sync-weave`, and
`--disable-inline-3d-occlusion` stays the escape hatch that beats an explicit opt-in. Pages get the
capability as a STATIC readonly `XRDisplayLayer.occlusionByDrawOrder` — static because it mirrors a
process-wide switch, is readable before any layer exists, and living on the interface object rather
than the prototype sidesteps Blink's illegal-invocation trap; it reads the RENDERER's own command
line, which is the same switch the GPU process's split runs under (one switch, three readers). With
that in place `excludeElement()`/`unexcludeElement()` become validate-and-no-op: arguments are still
checked, `composite:"under"` still throws `NotSupportedError` because 2D UNDER the weave is a
different pipeline and still unimplemented, and one throttled console warning per layer points the
author at `occlusionByDrawOrder`. Nothing is recorded — there is no consumer left, so keeping the set
would be a lie about what happens. Then the declared model goes, end to end: the `kInline3dOverlay`
tracked-element feature; `Inline3dExclusion` and its two rect lists on the frame metadata, with the
mojom struct, typemaps, traits and test; the cc plumbing behind them (`commit_state`,
`layer_tree_host`, `layer_tree_impl`, `layer_tree_host_impl`, `layer_context` and its three
implementations, `frame_widget`, `web_frame_widget_impl`) — taking care that 0049's viewport-fixed
split and 0056's scroll base each lose only their exclusion-typed half, because the canvas metadata
channel still needs the scroll shift; the aggregator's two-pass exclusion merge, the
exclusion→quad join with its `ID_JOIN_MISS`/`GEOM_FALLBACK`/`PROMOTION_LOST`/`UNCOMPOSITABLE`/
`EXCL_ABSENT` markers and per-id throttle, the overlay z-sort and the `quad_ordinal` that existed only
to feed it; `AggregatedFrame::inline_3d_overlays`; `display.cc`'s overlay resolve and
overlay-resource suppression; and in the GPU stage the Windows overlay atlas, both mac atlases, their
four members and the mac legacy overlay draw-back loop. Two keeps are deliberate: `best_match` stays
because the canvas ID-MATCH FALLBACK still calls it (a live dependency, not exclusion residue), and
the provider's `SetBatchOverlay`/`SetBatchOverlayMac` virtuals stay caller-less with a comment saying
why — that is the channel for handing the DP an over-plane to composite itself (Phase 3), the
runtime-side v4 contract is shipped, and keeping the binding costs nothing. What the kill switch means
changes with this patch and is worth stating plainly: with the atlas deleted,
`--disable-inline-3d-occlusion` turns off the plane split and leaves NO occlusion at all rather than
falling back to Phase 1, so undeclared 2D over a tile is woven again. That is intended — the switch
guards against plane-split bugs, not against needing a Phase-1 revert, which is now a revert of this
patch.
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
