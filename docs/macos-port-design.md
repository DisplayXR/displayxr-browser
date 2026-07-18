# macOS port design — inline-3D weave backend

Status: **design** (2026-07-18). The DisplayXR Browser builds + links on macOS today
(arm64, M150) with the inline-3D WebXR API surface compiled in; only the **weave
backend** is `BUILDFLAG(IS_WIN)`-gated (D3D11 + DirectComposition). This document is
the blueprint for porting that backend to macOS, consuming the runtime's macOS
`XR_DXR_weave` service (runtime #760: IOSurface in/out, synchronous, batched).

File:line citations are to `components/displayxr/**` and
`components/viz/service/display_embedder/displayxr_weave_provider.*` unless prefixed
`runtime:` (the displayxr-runtime tree).

## 0. The load-bearing decision: implement the SYNC path only

The Windows backend has two submit paths:

- **Async mojo path** (`SubmitInput`, gpu.cc:337) — GPU→browser over the
  `DisplayXRWeaver` mojo pipe, woven result one frame late. Exists *only* to dodge a
  banned `[Sync]` GPU-process mojo call + the GPU sandbox blocking the runtime RPC.
- **Sync GPU-process path** (`SubmitSync`/`SubmitBatchSync`, gpu.cc:364/588) — the
  OpenXR weave session is created **in the GPU process pre-sandbox** and
  `xrWeaveSubmitDXR` is called directly, in-process, synchronously — zero lag.

**The macOS runtime weave is synchronous by contract** (`XR_DXR_weave.md` §5;
`runtime:comp_multi_weave_macos.c` waits `vkWaitForFences` before the IPC reply). The
async path earns nothing on macOS — its whole reason to exist (a fence-less deadlock
dodge) is absent. **Port the sync GPU-process path only; leave the async mojo bridge +
its `gfx.mojom.DXGIHandle` typemap `IS_WIN`-gated.** This deletes the single hardest
mac piece (a mach-port/IOSurface mojom typemap) from the critical path.

## 1. One weave frame on Windows (sync mode) — the flow we mirror

1. **Pre-sandbox, GPU process (once):** `DisplayXRWeaveClient::PreSandboxInitializeForGpuProcess`
   → `InitializeCore` (client.cc:232): `XRT_FORCE_MODE=ipc`, `xrCreateInstance`
   (weave+rig exts), cache `XR_DXR_display_info`, resolve weave PFNs, create the
   graphics device on the runtime adapter, create a **present-owner session** bound to
   the browser window (real window + transparent + NULL shared texture),
   `xrWeaveBindWindowDXR`.
2. **Renderer:** Blink inline-3d session pulls per-frame views via `DisplayXRService`
   → `LocateViewsForRect` (client.cc:938) — a zone-scoped `xrLocateViews` so the
   **runtime** computes the off-axis (Kooima) frusta; the app renders its SBS pair.
3. **Viz / GPU main:** compositor tags the canvas quad as a weave target →
   `viz::DisplayXRWeaveProvider::WeaveCanvas` (gpu.cc:202): copy the canvas sub-rect
   into a per-target input texture, `SubmitSync`.
4. **Submit:** `xrWeaveSubmitDXR(input, rect)` → runtime weaves via the DP, returns
   dims + eyes + (first call) the woven-texture handle.
5. **Result → present:** viz `TryTakeWovenResult` → `SkiaOutputSurfaceImplOnGpu`
   imports the woven texture, GPU-waits the fence, composites it as a
   **DirectComposition** overlay at the window rect, presents.

## 2. Transport substitution (Windows → macOS)

| Concept | Windows | macOS |
|---|---|---|
| Input texture | D3D11 keyed-mutex shared tex, legacy-DXGI HANDLE | **IOSurfaceRef** (Metal-backed), crosses IPC as global IOSurfaceID |
| `inputTexture` / `inputIsDxgi` | HANDLE / TRUE | `(void*)IOSurfaceRef` / ignored (spec §5) |
| Input-ready sync | keyed-mutex `AcquireSync(0)` | finish Metal writes **before** submit (no mutex) |
| Woven output | shared NT HANDLE + D3D fence | **retained IOSurfaceRef**, **no fence** |
| Fence wait before sampling | `GPUWait(fence, value)` | **dropped** — submit returned ⇒ GPU-complete |
| Canvas→input copy | `CopySubresourceRegion` (D3D11) | `MTLBlitCommandEncoder` copy |
| Compose | DirectComposition visual | **CALayer / `CARendererLayerTree` IOSurface overlay** |
| Window bind | real HWND, phase-snap + `GetClientRect` | NSWindow/CGWindowID, **stored only**; snap = identity |
| `xrWeaveBindWindowDXR` | HWND | `runtime:comp_multi_weave_bind_window` (stores id) |
| `xrWeaveSubmitDXR` | D3D11 handle | `runtime:comp_multi_weave_submit` (IOSurface, sync) |
| `xrWeaveSnapWindowRectDXR` | DP lattice snap | `runtime:comp_multi_weave_snap_window_rect` = identity |

**Dropped, not ported (no macOS analogue / not needed):** the async mojo bridge
(`weaver_impl.*`, the `DXGIHandle` mojom), the drag phase-snap window subclass
(`DisplayXRWndSubclassProc`), the process-DACL widen (IOSurfaces cross by global
IOSurfaceID — no handle duplication), and the NT-vs-legacy-handle branch.

## 3. The `IS_WIN` gates → mac branches (21 sites)

Split each Windows `.cc` into a platform-neutral dispatcher + a `_win`/`_mac` TU:

- **`displayxr_weave_client_mac.mm`** (Obj-C++): `WeaveClientState` with
  `id<MTLDevice>` + `IOSurfaceRef` fields. `InitializeCore` mac: `setenv XRT_FORCE_MODE=ipc`;
  session via **`XrGraphicsBindingMetalKHR`** (`XR_USE_GRAPHICS_API_METAL`) +
  **`XR_DXR_cocoa_window_binding`** (transparent) instead of the Win32 binding;
  `xrWeaveBindWindowDXR(session, 0)` (runtime just stores it). Time conversion in
  `LocateViewsForRect`: `QueryPerformanceCounter`/`xrConvertWin32...` →
  `clock_gettime(CLOCK_MONOTONIC)` + `XR_KHR_convert_timespec_time`. `SubmitWin` mac:
  `inputTexture = (void*)ioSurfaceRef`, `inputIsDxgi=FALSE` (ignored); the
  `XrWeaveSubmitInfoDXR`/`XrWeaveSubmitRectsDXR` fill + eyes read-back are **identical**
  (OpenXR structs are platform-neutral; woven handle comes back via `weave_get_output`
  as the IOSurfaceID).
- **`displayxr_weave_gpu_mac.mm`**: implements `viz::DisplayXRWeaveProvider` with
  `id<MTLDevice>`/`id<MTLCommandQueue>` + per-target `IOSurfaceRef`. `WeaveCanvas` mac:
  the canvas SharedImage is IOSurface-backed → `MTLBlitCommandEncoder` its `src_rect`
  into the per-target input IOSurface, `-waitUntilCompleted`, `SubmitSync` (no
  `SnapWindowIfMoved`). `ResetInput`/`CloseResultHandles` → `CFRelease`.
- **`displayxr_weave_provider.h`**: de-D3D-ify the interface — the signatures are
  `ID3D11Device*`/`ID3D11Texture2D*`/`UINT array_slice`. Replace with an opaque
  canvas-image handle (viz overlay-image / `gpu::Mailbox`), or a parallel mac-typed
  method set under `#if BUILDFLAG(IS_MAC)`. `Result`, `TryTakeWovenResult`,
  `PruneTargets`, and the batch trio are already platform-neutral.
- **Viz compose:** hand the woven `IOSurfaceRef` to viz as a `gfx::ScopedIOSurface`
  overlay and add it to the **`CARendererLayerTree`** (`ui/gl/ca_renderer_layer_tree`
  / `image_transport_surface_overlay_mac`) at the element rect — the native DComp
  analogue; **no fence wait**. Reuses existing mac IOSurface-overlay plumbing.
- **`weaver_impl.{cc,h}` + the mojom `WeaveSubmit`/`DisplayXRWeaveResult`:** not built
  on mac (async bridge dropped) — keep `[EnableIf=is_win]` / `IS_WIN`.

## 4. openxr-loader linkage

Windows links `openxr_loader.lib` + **delay-loads** `openxr_loader.dll` (patch 0040)
so the browser launches dormant when no runtime is installed. macOS analogue:
**weak-link `libopenxr_loader.dylib`** (`-weak_library …` / `-weak-lopenxr_loader`) —
or `dlopen`/`dlsym` `xrGetInstanceProcAddr` — so missing symbols resolve NULL and the
existing `has_weave`/session guards keep inline-3d dormant. BUILD.gn:

- **browser/BUILD.gn** — `else if (is_mac)`: weak `//third_party/displayxr:openxr_loader_mac`,
  `frameworks = [ IOSurface, CoreFoundation, Metal, QuartzCore ]`, drop
  `advapi32/comctl32/d3d11/dxgi`, add `displayxr_weave_client_mac.mm`.
- **gpu/BUILD.gn** — `else if (is_mac)`: `frameworks = [ Metal, IOSurface, QuartzCore ]`,
  add `displayxr_weave_gpu_mac.mm`.
- **common/BUILD.gn** — unchanged (`[EnableIf=is_win]` keeps the bridge Windows-only).

## 5. Implementation order (smallest-risk first)

- **PR1 — scaffolding + loader de-risk (mirror of B2a).** De-D3D-ify `provider.h`; add
  `_mac.mm` skeletons + BUILD.gn mac branches + weak-linked loader; implement only
  `InitializeCore`(mac) + `IsSupported`. Gate: `--enable-inline-3d` on macOS logs
  "instance+system OK, weave PFNs resolved, session bound". **The linking/process
  unknowns concentrate here — do it first.**
- **PR2 — eyes/views (no pixels).** Port `LocateViewsForRect`→mac (timespec time-conv).
  Gets `isSessionSupported('inline-3d')` + per-frame views end-to-end.
- **PR3 — GPU-process sync weave (critical path).** `DisplayXRWeaveGpuMac`: Metal
  canvas-IOSurface → input-IOSurface blit, `SubmitSync`, `CFRetain`/`CFRelease` results.
  Headless-verifiable vs `runtime:test_apps/probes/weave_probe_vk_macos` (anaglyph CPU check).
- **PR4 — Viz compose (critical path, pairs with PR3).** Woven IOSurface →
  `CARendererLayerTree` overlay at the window rect, no fence wait. PR3+PR4 = first light.
- **PR5 — batch (spec v3), optional perf.** One shared window-sized input IOSurface,
  per-element Metal blits, one `SubmitBatch`. Lifts the visible-element ceiling.

**Critical path: PR3 + PR4** (gated by PR1). PR2 and PR5 are independently shippable.

## 6. Open questions to verify in the live tree

1. **Canvas SharedImage → IOSurface on mac** (biggest unknown) — exact API to get the
   backing `IOSurfaceRef` from the viz canvas SharedImage/overlay on the GPU thread
   (`IOSurfaceImageBacking::GetIOSurface()`? the `gfx::ScopedIOSurface` on the overlay
   image?). Determines PR3's shape.
2. **Woven IOSurface → CALayer overlay** — the viz entry point to inject an
   externally-owned IOSurface as a `CARendererLayerTree` overlay at a chosen rect.
3. **Cross-device IOSurface coherence** — service `MTLDevice` may differ from the
   browser GPU-process `MTLDevice`; confirm the synchronous completion (no explicit
   `MTLSharedEvent`) suffices on real dual-device hardware.
4. **GPU-process seatbelt vs runtime socket** — confirm the pre-sandbox init can open
   the `displayxr-service` unix socket before the mac seatbelt profile applies and the
   fd survives.
5. **Browser NSWindow id → GPU process** — pass 0 for now (runtime stores + identity
   snap); plumb a real CGWindowID only when a lattice-bearing mac DP exists.
6. **Metal present-owner session** — confirm the runtime macOS service accepts an
   `XrGraphicsBindingMetalKHR` present-owner session + `XR_DXR_weave`; if it requires a
   Vulkan binding, the client creates a MoltenVK device instead of a raw `MTLDevice`.
