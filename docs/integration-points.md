# Inline-3D integration points — the file set the patch touches

The `patches/` series is small and touches a **known, enumerated** set of files. That is what makes a
monthly milestone rebase mechanical: when a rebase conflicts, it can only conflict in one of these
files, and each has a documented role. The design rationale for every hook lives in the runtime repo:
[`docs/roadmap/webxr-step-b-design.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-step-b-design.md)
§13 (+ `displayxr-browser-preview.md`).

The series is **15 commits, 117 files** — but ~30 of those are the vendored OpenXR SDK
(`third_party/displayxr/`, pure additions, never conflict). The real integration surface is **~87
files** across six areas below. Additive files (new `.cc/.h/.mojom` that Chromium doesn't have) never
conflict; the **edit sites** in existing Chromium files are the only rebase-fragile spots and are called
out with ⚠.

## 1. Blink — the WebXR JS surface (`inline-3d` + `XRDisplayLayer`)
The web-facing API: an `inline-3d` session mode and an `XRDisplayLayer` bound to a DOM canvas that
reports its rect + consumes the eyes the runtime supplies. 2D-over-3D occlusion needs **no page
declaration**: the static `XRDisplayLayer.occlusionByDrawOrder` reports the capability, and
`excludeElement(el)` / `unexcludeElement(el)` survive only as validate-and-warn no-ops for pages
written against the retired declared model (`composite:"under"` still throws).
- **New:** `third_party/blink/renderer/modules/xr/xr_display_layer.{h,cc,idl}`, `xr_display_layer_init.idl`,
  `xr_display_layer_exclusion_init.idl` (kept for the deprecated `excludeElement` signature)
- **New:** `third_party/blink/public/mojom/xr/displayxr_service.mojom` (eyes + display-info → renderer)
- ⚠ **Edit:** `xr_session.{cc,h,idl}` (inline-3d session, 2-view off-axis Kooima frusta, rect report,
  the three animation gates that must open for a sensorless inline session), `xr_system.{cc,h}`
  (`isSessionSupported('inline-3d')`, service remote), `xr_frame_provider.cc` (focus-gate bypass),
  `html_canvas_element.h`, `web_frame_widget_impl.{cc,h}`, `platform/widget/frame_widget.h`
- ⚠ **Edit (regenerates bindings — slow rebuild):** `runtime_enabled_features.json5`
  (`DisplayXRInline3D`), `bindings/{idl,generated}_in_modules.gni`

## 2. cc — carry `inline_3d_rects` from the renderer to Viz
The canvas rects ride the compositor frame so they arrive at Viz atomically with the pixels they
describe (kills one-frame staleness). Mirrors how `tracked_element_rects` are plumbed. ONE list:
`layer_tree_host_impl.cc` shifts it by (current impl scroll − the measurement-time base Blink
stamped), so a rect still matches its quad mid-fling.
- ⚠ **Edit:** `cc/trees/commit_state.{cc,h}`, `layer_tree_host.{cc,h}`, `layer_tree_host_impl.{cc,h}`,
  `layer_tree_impl.{cc,h}`, `layer_context.h`, `cc/mojo_embedder/viz_layer_context.{cc,h}`
- ⚠ **Edit (signature must match base + test impls):** `cc/test/{fake,test}_layer_context.{cc,h}`

## 3. viz — metadata plumbing + the weave hook
`inline_3d_rects` on the compositor-frame metadata + LayerContext update; the actual weave runs on the
GPU thread post-paint / pre-swap.
- ⚠ **Edit:** `components/viz/common/quads/compositor_frame_metadata.{cc,h}`,
  `services/viz/public/mojom/compositing/{compositor_frame_metadata,layer_context}.mojom` +
  `.../cpp/compositing/compositor_frame_metadata_mojom_traits.{cc,h}`
- ⚠ **Edit:** `viz/service/display/{display.cc,surface_aggregator.{cc,h},aggregated_frame.h,`
  `direct_renderer.{cc,h},skia_output_surface.h,skia_renderer.cc,external_use_client.h}`,
  `viz/service/layers/layer_context_impl.cc`
- **The weave core:** `viz/service/display_embedder/skia_output_surface_impl_on_gpu.{h,cc}` —
  `WeaveCompositedSurface` (+ `prefer_zero_copy`), `MaybeWeaveOutput` (GL path), `MaybeWeaveRootRenderPass`
  (DComp root render-pass path). Also `skia_output_surface_impl.{cc,h}`.

  **Canvas resource join.** The aggregator records every resource-bearing quad
  `{ResourceId, root-space rect, uv, SQS layer id, pass id}` and joins each inline-3D canvas to its
  quad by **layer identity**, with a 70%-overlap geometric `best_match` as the fallback. **Not just
  root-pass quads** (0081): a canvas inside the render surface a `backdrop-filter` forces onto its
  enclosing effect node (`RenderSurfaceReason::kBackdropScope`) draws into a CHILD pass, so a
  root-only search could never find it. A child-pass match is only accepted if the pass reaches the
  root through trivially composited `RenderPassDrawQuad`s (opacity 1, `kSrcOver`, no filters/mask,
  axis-aligned) — the weave draw-back is a root-space blit and cannot reproduce anything else.
  **Submission is in lockstep with preparation** (0081): a tile with no resolved canvas resource is
  not suppressed from the page raster, so its rect is withheld from the weave submission entirely —
  weaving it would interlace whatever page content happens to be there. `Display` resolves `ResourceId → gpu::Mailbox`
  (`DisplayResourceProvider::GetMailbox`) and hands the GPU stage `{mailbox, rect}`;
  `WeaveCompositedSurface` sources the weave INPUT from that canvas resource (clean SBS — falls
  back to the composited output sub-rect). Root-space rect = quad SQS `quad_to_target_transform`
  then `transform_to_root_target`.

  **2D-over-3D by DRAW ORDER.** Page content over a woven tile is occluded correctly with nothing
  declared. `DirectRenderer::ComputeInline3dPlaneSplit` walks the live `quad_list` at DRAW time
  — never the aggregation-time ordinals, which `RemoveOverdrawQuads()` and `ProcessForOverlays()`
  erase and reorder — finds each tile's canvas quad at index `k`, and takes the intersecting quads
  in front of it as the OVER set (`[0, k)`; index 0 is frontmost). It descends from the root into
  child passes that touch a tile (0081); a tile whose home pass is not the root gets **no**
  over-plane — lifting a quad out of a child pass changes what it composites against — and instead
  gets the D-prime treatment for every quad in front of it, in its own pass and up the ancestor
  spine: those rects are clipped out of the woven draw-back and wished flat.
  `SkiaRenderer::MaybeDrawInline3dOverPlane` paints that set into a window-sized transparent premul
  RGBA8 plane through the root pass's target-to-device transform, so each quad lands in identical
  device pixels; a difference clip punches the tile rects out of the page draw; and phase (B) of
  `WeaveCompositedSurface` composites the plane `kSrcOver` over the whole window after the woven
  draw-back — which is what puts the lifted content genuinely ON TOP of the weave. A plane whose
  size does not match the window is skipped, never sampled. Entirely browser-side; no runtime/DP
  change.

  Content that cannot be lifted, and is therefore still woven — each counted by reason in the
  throttled `[DisplayXR] inline-3D plane-split:` marker: `backdrop-filter` and **all** render-pass
  quads (pixel-moving filters exist, so "it only wraps one pass" is not safe), non-`kSrcOver` blend
  modes, 3D sorting contexts, and protected video (`RequiresOverlay`).

  Selected by `--inline-3d-occlusion`, appended by default in `chrome_main_delegate.cc` and
  forwarded to the GPU process (the split) and the renderer (`occlusionByDrawOrder`).
  `--disable-inline-3d-occlusion` is the kill switch; it disables the plane split only — there is
  no declared-exclusion path left to fall back to.
- **New:** `viz/service/display_embedder/displayxr_weave_provider.{cc,h}` (`WeavePixels` + `WeaveCanvas`)

## 4. gpu — the two additive `ProduceOverlayForWeave` methods (the rebase-fragile layer)
The only shared-image-layer surgery. `ProduceOverlayForWeave` = `ProduceOverlay` minus the SCANOUT gate;
it is how the zero-copy path gets a raw `ID3D11Texture2D` out of a Viz SharedImage under Graphite-Dawn.
- ⚠ **Edit (Win-only, additive):** `gpu/command_buffer/service/shared_image/shared_image_manager.{cc,h}`,
  `shared_image_factory.{cc,h}`

## 5. components/displayxr — the shared weave component (browser + gpu)
Layer-agnostic; consumed by both `chrome` and `content_shell`. All **new** files — never conflict.
- `components/displayxr/common/displayxr_weave.mojom`
- `components/displayxr/browser/displayxr_{weave_client,weaver_impl,service_impl}.{cc,h}`
- `components/displayxr/gpu/displayxr_weave_gpu.{cc,h}` + the three `BUILD.gn`

## 6. Embedder hooks — wire the component into chrome (and content_shell)
Three hook sites each, mirrored onto both embedders. `content/shell/*` is carried for fidelity/debug;
**the browser product builds `chrome`.**
- ⚠ **Edit (chrome):** `chrome/browser/chrome_browser_main.cc` (weave-client init, delayed UI task),
  `chrome_content_browser_client.cc` (+ `AppendExtraCommandLineSwitches` FORCE_HIGH_PERFORMANCE_GPU,
  `BindGpuHostReceiver`), `chrome_content_browser_client_receiver_bindings.cc`,
  `chrome_browser_interface_binders.cc` (frame binder), `chrome/gpu/chrome_content_gpu_client.{cc,h}`,
  `chrome/browser/BUILD.gn`, `chrome/gpu/BUILD.gn`
- ⚠ **Edit (content_shell, mirror):** `content/shell/browser/shell_browser_main_parts.cc`,
  `shell_content_browser_client.{cc,h}`, `content/shell/gpu/shell_content_gpu_client.{cc,h}`,
  `content/shell/BUILD.gn`

## 7. Vendored OpenXR SDK (pure additions — never conflict)
`third_party/displayxr/` — the OpenXR loader (`bin/openxr_loader.dll`, `lib/openxr_loader.lib`) + the
DisplayXR extension headers + a `BUILD.gn` `:openxr_loader` group that stages the DLL next to the exe.
Preserved in the patch as binary hunks (`git format-patch --binary`).

---

**Rebase heuristic:** if `git am` conflicts, it will be in a ⚠ file. Re-read that hook's role above +
the matching §13 subsection, resolve against the new milestone's code, then re-verify the weave
(docs/rebase-runbook.md). A conflict in a **new** file means upstream added a file of the same name —
rare; rename ours.
