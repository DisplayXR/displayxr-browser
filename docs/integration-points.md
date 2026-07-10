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
reports its rect + consumes the eyes the runtime supplies.
- **New:** `third_party/blink/renderer/modules/xr/xr_display_layer.{h,cc,idl}`, `xr_display_layer_init.idl`
- **New:** `third_party/blink/public/mojom/xr/displayxr_service.mojom` (eyes + display-info → renderer)
- ⚠ **Edit:** `xr_session.{cc,h,idl}` (inline-3d session, 2-view off-axis Kooima frusta, rect report,
  the three animation gates that must open for a sensorless inline session), `xr_system.{cc,h}`
  (`isSessionSupported('inline-3d')`, service remote), `xr_frame_provider.cc` (focus-gate bypass),
  `html_canvas_element.h`, `web_frame_widget_impl.{cc,h}`, `platform/widget/frame_widget.h`
- ⚠ **Edit (regenerates bindings — slow rebuild):** `runtime_enabled_features.json5`
  (`DisplayXRInline3D`), `bindings/{idl,generated}_in_modules.gni`

## 2. cc — carry `inline_3d_rects` from the renderer to Viz
The canvas rects ride the compositor frame so they arrive at Viz atomically with the pixels they
describe (kills one-frame staleness). Mirrors how `tracked_element_rects` are plumbed.
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
  `skia_output_surface.h,skia_renderer.cc,external_use_client.h}`,
  `viz/service/layers/layer_context_impl.cc`
- **The weave core:** `viz/service/display_embedder/skia_output_surface_impl_on_gpu.{h,cc}` —
  `WeaveCompositedSurface` (+ `prefer_zero_copy`), `MaybeWeaveOutput` (GL path), `MaybeWeaveRootRenderPass`
  (DComp root render-pass path). Also `skia_output_surface_impl.{cc,h}`.
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
