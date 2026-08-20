# Android port — inline-3D weave on the DisplayXR Android runtime

**Goal.** Run the `displayxr-web` **`samples/windows`** suite on the **NP02J** tablet, woven
glasses-free, against the merged `displayxr-runtime` `main`. That page is the acceptance target
because it exercises every input class in one document: five side-by-side PNG tiles, one VP9 SBS
video tile, and one live three.js scene tile, with ordinary 2D page content scrolling around and
over them.

This is a **port of the existing series onto a third backend**, not a redesign. The Windows
patches established the mechanism; patch **0052** turned `DisplayXRWeaveClient` and
`viz::DisplayXRWeaveProvider` into platform dispatchers and added macOS as the second arm. Android
is the third arm of that same dispatcher. Mirror the `_mac` files; do not re-architect.

The runtime side is already merged and specified — cite it, don't re-derive it:

| Contract | Spec |
|---|---|
| Getting a runtime IPC socket into a sandboxed child | [`docs/specs/runtime/android-ipc-fd-adoption.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/specs/runtime/android-ipc-fd-adoption.md) |
| The weave calls, handles, and Android platform mapping | [`docs/specs/extensions/XR_DXR_weave.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/specs/extensions/XR_DXR_weave.md) §5b (v7) |
| Why geometry must be published every frame | [`ADR-036`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/adr/ADR-036-android-per-window-compositor-instances.md) D6 |
| A working end-to-end client | `test_apps/weave/weave_client_vk_android/` — `RuntimeFdConnector.kt`, `WeaveGpuService.kt`, `src/main/cpp/main.cpp` |

Read the reference client before writing any of this. Its comments are load-bearing.

## Patch disposition

`patches/` grows weekly — **count it, never quote a number.** At the time of writing the series is
69 commits. The split:

| Class | Count | Notes |
|---|---|---|
| Portable unchanged | ~47 | All of Blink / `cc` / `viz` core, including **0057–0069**. Verified: 0061 is the *only* patch in 0057–0069 that touches a per-platform file. |
| Windows-only, **dropped** | 7 | 0010, 0016, 0017, 0019, 0024, 0025, 0040 |
| Needs an Android analogue | ~15 | 0001, 0002, 0004, 0005, 0013, 0015, 0023, 0036, 0041, 0052, 0053, 0054, 0061, 0066, 0069 |

### The seven Windows-only drops

macOS shipped without an analogue for any of these, which is the evidence that they are Win32
accidents rather than requirements:

- **0010** (force high-performance GPU adapter) — a cross-adapter NT-handle problem. One GPU.
- **0016** (`Chrome_WidgetWin_*` window-class filter) — guards a top-level-**HWND** enumeration race.
- **0017** (retry the window bind) — Android publishes geometry from Java, not by racing for a handle.
- **0019** (bind-retry budget 20→120) — same family as 0017.
- **0024** (`xrWeaveSnapWindowRectDXR` on window move) — the runtime owns interlace phase (ADR-033);
  mac proved an identity window-snap suffices, and Android's window is fullscreen anyway.
- **0025** (`WM_WINDOWPOSCHANGING` phase-grid drag constraint) — no draggable window, no Win32 message.
- **0040** (delay-load `openxr_loader.dll`) — a PE import/sandbox artefact. Android `dlopen`s.

### 0036, the one-liner

Swap `XR_KHR_win32_convert_performance_counter_time` for `XR_KHR_convert_timespec_time`.

### 0061, the per-backend hook

0061 added a pure-virtual `PruneTarget(uint32_t target_id)` to `viz::DisplayXRWeaveProvider`. The
mac override in `displayxr_weave_gpu_mac.mm` is seven lines (a `results_.erase(target_id)`) because
mac keeps no per-target GPU resources. The Android backend must supply its own override, releasing
whatever per-target `AHardwareBuffer` / fence state it holds — trivial if it copies mac's
single-shared-input design, real work if it does not.

Everything else reduces to **three mechanisms**.

---

## M1 — texture extraction (0005, 0015, 0053)

`ProduceOverlayForWeave()` on `SharedImageManager`/`SharedImageFactory` is `ProduceOverlay()` minus
the SCANOUT gate — the only shared-image-layer surgery in the series, and the only way to get a raw
platform texture out of a Viz `SharedImage` under Graphite-Dawn. It is already
`#if BUILDFLAG(IS_WIN) || BUILDFLAG(IS_APPLE)`; widen it to Android. The extraction chain is
identical on all three platforms up to the last step:

```
ProduceOverlayForWeave(mailbox) -> OverlayImageRepresentation
  -> BeginScopedReadAccess()
    Windows: GetDCLayerOverlayImage()->d3d11_video_texture()  -> ID3D11Texture2D*
    macOS:   GetIOSurface()                                   -> gfx::ScopedIOSurface
    Android: GetAHardwareBuffer()                             -> ScopedHardwareBufferFenceSync
```

`ScopedHardwareBufferFenceSync` carries both halves we need: the `AHardwareBuffer*` and
`TakeFence()`, a `sync_file` fd for the writes that produced it.

The scratch/atlas SharedImages that 0015 and 0053 allocate (the window-sized weave input and the
DP-composited 2D overlay atlas) must be **AHB-backed** — allocate with `SCANOUT` usage so the backing
routes to the AHardwareBuffer path, exactly as `SCANOUT` routes to `IOSurfaceImageBacking` on mac,
keeping them simultaneously Skia-writable and overlay-readable.

### Fences: who waits on what

**The runtime has no acquire fence on Android.** `XR_DXR_weave.md` §5b states the input-ready
contract as *"caller finishes writes before submit"*, and the completion side as *"no fence —
completion is SYNCHRONOUS (bounded 1 s wait server-side)"*. The reference client says it plainly
(`main.cpp:930-933`): *"there is no acquire fence on this platform yet (#1036 follow-up), so this
wait is the contract, not laziness."*

So the GPU process must be **GPU-complete before `xrWeaveSubmitDXR`**, and there are two fences:

1. **The producer's fence, inbound.** The canvas AHB may still be being written when we get it. Take
   `ScopedHardwareBufferFenceSync::TakeFence()` and either import it as a Vulkan semaphore
   (`vkImportSemaphoreFdKHR`, `VK_SEMAPHORE_IMPORT_TEMPORARY_BIT`) and wait on it in the blit submit,
   or `sync_wait()` it on the CPU. The CPU wait is simpler and usually free — Viz has typically
   already flushed — and it is what the first cut should do.
2. **Our own blit's fence, outbound.** The copy of each canvas AHB into the shared window-sized input
   AHB must be finished, not merely submitted. Submit it with a `VkFence` and
   `vkWaitForFences(..., UINT64_MAX)` before calling `xrWeaveSubmitDXR` — the reference client's
   `upload_input()` does exactly this. Where the copy goes through Skia/Graphite rather than raw
   Vulkan, the equivalent is a submit-and-wait-for-CPU-sync flush, not a bare `flush()`.

The cost is one CPU stall per frame on Viz's present thread, on top of the already-synchronous
submit (≈1 ms fixed per submit; 5.5–6.4 ms measured at 2560×1412). The runtime's documented
follow-up is an fd-based `sync_file` acquire/release pair, which deletes both waits — measure the
stall on device and file the number against it.

---

## M2 — session bring-up (0001, 0002, 0023)

On Windows, 0023 creates the present-owner OpenXR session **inside the GPU process** in
`PreSandboxStartup()` — the sandbox blocks *opening* the runtime pipe, not I/O on an already-open
handle. Android has no such pre-sandbox window: the GPU process cannot bind the runtime service at
all. Hence the fd-adoption design (#1056).

**Step 1 — browser process, Java.** Reflectively load the runtime's IPC client out of the installed
runtime APK and connect:

- `createPackageContext(runtimePkg, CONTEXT_INCLUDE_CODE | CONTEXT_IGNORE_SECURITY)`
- class `org.freedesktop.monado.ipc.Client`, constructor `Client(long nativePointer)`
- `blockingConnect(applicationContext, runtimePkg)` — **must** be the application context, not an
  Activity, or the binding dies with the Activity
- read the `fd` field (a `ParcelFileDescriptor`), `.dup()` it for the handoff
- **keep the `Client` instance alive for the entire browser-process lifetime.** Dropping it unbinds
  the service and releases the slot.

`RuntimeFdConnector.kt:51-89` is this, verbatim. Budget 283–372 ms for the connect (measured on
NP02J) — it must not be on a critical startup path.

**Step 2 — hand the fd to the GPU process.** Chromium already has the transport: a
`base::GlobalDescriptors` key populated via
`ContentBrowserClient::GetAdditionalMappedFilesForChildProcess()` (`PosixFileDescriptorInfo`), or the
dup'd fd sent over the existing `displayxr_weave.mojom` pipe. **Prefer the Mojo route**: it decouples
the ~300 ms connect from process launch and makes reconnect identical to first-connect.

**Step 3 — publish before the first OpenXR call.** In `content/gpu/gpu_main.cc`, either
`setenv("DXR_IPC_FD", n)` (Android has one bionic libc per process, so `setenv` genuinely works —
unlike the Windows static-CRT trap) or call the explicit
`ipc_client_connection_adopt_fd(int fd)`. Both are consumed once, by the next
`ipc_client_connection_init()`. The explicit call needs the symbol: the loader `dlopen`s the runtime
`RTLD_LOCAL`, so `dlsym(RTLD_DEFAULT, …)` may miss it — use
`dlopen("openxr_displayxr.so", RTLD_NOLOAD | RTLD_NOW)` then `dlsym` on that handle
(`main.cpp:236-260`).

**The git-tag gate.** `ipc_client_check_git_tag()` (`src/xrt/ipc/client/ipc_client_connection.c:648`)
`strncmp`s the client library's compiled-in `u_git_tag` against the running service's, and fails
`xrCreateInstance` on any mismatch. The browser must therefore load the **device's** runtime `.so`,
resolved through the installed runtime package — never a self-built or bundled copy. This is what
0001 (vendored `openxr_loader.dll` + `.lib`) becomes on Android: vendor the OpenXR **loader** only.

**Reconnect after a GPU-process crash.** Slot ownership and the death-link attribute to the
*connector* — `SO_PEERCRED` names the browser process, not the adopter — so a GPU crash does not free
the slot. The browser keeps its `Client` and, on GPU relaunch, performs a fresh socketpair + fd
handoff. That is exactly why the connector/adopter split exists. Note the **`PRESENT_OWNER` quota is
2 system-wide**: a leaked session surfaces as `XR_ERROR_LIMIT_REACHED` out of `xrCreateInstance`, so
the browser must hold exactly one and release it on shutdown.

---

## M3 — compositing gates and geometry (0004, 0013, 0041, 0054, 0066, 0069)

**(a) The compositing gate.** 0041 force-disables the `DelegatedCompositing` feature in
`ChromeMainDelegate::BasicStartupComplete()` under `--enable-inline-3d`, because delegated
compositing decomposes the page into DComp visuals and leaves the root render pass with nothing to
weave. Android's equivalent hazard is **SurfaceControl / overlay promotion**: a canvas quad promoted
to its own `SurfaceControl` layer never reaches the root pass, and `WeaveCompositedSurface()` finds
nothing. Mirror 0041 — disable overlay promotion (at minimum for frames carrying `inline_3d_rects`)
in the same `BasicStartupComplete()` hook. **Open item:** determine whether Android's
`SkiaOutputDevice` enters via `MaybeWeaveOutput()` (the GL path) or `MaybeWeaveRootRenderPass()`
(0013's DComp path). If it is the former, 0013 needs no Android arm at all.

**(b) Window geometry.** There is no HWND and no window-move event — ADR-036 D6 is explicit that
Android raises no resize on a pure move, because SurfaceFlinger repositions the layer with the stale
buffer. Geometry therefore comes from the Java UI: sample `View.getLocationOnScreen()` on the content
view in a `Choreographer` callback, ship it to the GPU process over `displayxr_weave.mojom`, and
apply it as `xrWeaveBindWindow2DXR` with a chained
`XrWeaveWindowGeometryDXR { windowOriginOnScreen, clientSize, displayId }` — **required** on Android,
optional elsewhere. Re-bind on move and on resize; the runtime dedupes, so republishing every frame
is safe. This single channel replaces the entire dropped 0016/0017/0019/0024/0025 family. Per
ADR-033 the browser reports geometry and nothing else; the weaver alone owns phase and snapping.

**(c) Foreground-tab demand.** 0054, 0066 and 0069 all live in
`chrome/browser/displayxr/displayxr_display_mode_controller.*` and are built on
`BrowserWindowInterface`, `ForEachCurrentBrowserWindowInterfaceOrderedByActivation()` and
`views::Widget` — **all desktop-only**. Android needs a parallel controller driven by
`TabModelSelector` / `TabModel` observers (`onTabSelected`, tab closure, navigation start) reaching
C++ over JNI, expressing the same three edges: acquire demand on a foreground inline-3D tab, retract
it on navigation (0066), and force 2D at shutdown. Two build traps: the desktop controller must be
removed from the `chrome_public_apk` source list rather than `#ifdef`ed, and 0069's
popup-occluder TU is `#if BUILDFLAG(IS_WIN)`-guarded *internally* but `#include`s `ui/views/…`
unconditionally, so it must be gated in `BUILD.gn`, not in the `.cc`.

**(d) The mojom handle.** `displayxr_weave.mojom` currently carries a `gfx.mojom.DXGIHandle`. Make it
a platform-neutral union over `{ DXGIHandle, IOSurface id, AHardwareBuffer handle }` rather than
adding a parallel interface. Note the transport trap from `XR_DXR_weave.md` §5b:
`AHardwareBuffer_recvHandleFromUnixSocket` **blocks** on a mismatched handle count, so whatever
framing the mojom uses must state the count exactly.

On the wire, the Android submit is: `XrWeaveSubmitInfoDXR { inputTexture = <AHardwareBuffer*>,
firstChunk = XR_TRUE }` ← chained `XrWeaveSubmitRectsDXR` (1..32, batch — the fixed ≈1 ms is per
*submit*, not per rect) ← chained `XrWeaveSubmitHandlesDXR { inputKind =
XR_WEAVE_HANDLE_KIND_AHARDWAREBUFFER_DXR }`. Declaring the handle kind is mandatory;
`PLATFORM_DEFAULT` is wrong on Android. `XrWeaveOutputDXR::weavedTexture` is non-NULL only on the
first submit and on every reallocation; cache it, and `AHardwareBuffer_release()` the old one when
it is replaced.

---

## Build lane

Chromium's Android build is Linux-only, so the Windows box cannot do it. The lane is parallel, not
shared:

- `target_os = "android"`, `target_cpu = "arm64"`, target `chrome_public_apk`, in a new
  `scripts/args.android.gn` alongside `args.official.gn`.
- `.gclient` needs `target_os = ['android']` and the checkout needs
  `build/install-build-deps.sh --android`. `scripts/fetch.sh` grows an Android branch; the pin still
  comes from `scripts/config.env` and nowhere else.
- Built on the **EC2 Linux builder**. Its coordinates live in `.env.local` (`DXR_LINUX_BOX_*`) and
  its key in `.secrets/` — **both gitignored, never commit either.** The box is **stopped when idle
  and never terminated**; terminating loses the multi-hour checkout.
- CI: a `build-box-android.yml` mirroring `build-box.yml`'s start → wait-for-agent → build →
  `if: always()` stop shape, and the same "sync `patches/` from this repo" rule so the box builds
  exactly what is committed here.
- Signing: `chrome_public_apk` self-signs with the debug key, which is fine for bring-up. A release
  keystore + `apksigner` step comes later, with branding; keep it out of the early milestones.

**M0 is a vanilla build.** Build `chrome_public_apk` at the pinned tag with **no patches applied**,
install it on the device, and confirm it runs. That separates toolchain, box, gclient, adb and
device problems from patch problems, and it is cheap relative to debugging them together later.

---

## Test plan

**Serving.** `python -m http.server 8080` on the host, `adb reverse tcp:8080 tcp:8080` on the device,
then `http://localhost:8080/` — which counts as a secure context, so WebXR is available. (`file://`
does not.) The published samples at <https://displayxr.github.io/displayxr-web/> work too.

**Detection contract** (from the web SDK):

```js
const available = !!navigator.xr && typeof window.XRDisplayLayer === 'function';
// then, authoritatively:
const session = await navigator.xr.requestSession('inline-3d');
```

`isSessionSupported()` is *not* authoritative — it false-negatives when probed before the weave
session has bound. A succeeding `requestSession('inline-3d')` is the gate.

**Step 1 — minimal page.** One canvas, one static SBS image, nothing else. Proves detection, session
creation, geometry publication, and one woven tile. Do not move on until this is clean.

**Step 2 — `samples/windows`.** Seven tiles: five SBS PNGs via `addImage` (cornerRadius 28), one VP9
SBS WebM via `addVideo`, one live three.js crate via `addScene` at `virtualDisplayHeight` 0.24 m.
Checklist:

- [ ] all seven tiles weave simultaneously (one batched submit per frame, ≤32 rects)
- [ ] tiles stay phase-locked under page scroll and fling
- [ ] 2D page content drawn over a tile composites correctly (occlusion by draw order, 0063–0065)
- [ ] switching to another tab retracts demand; the panel returns to 2D
- [ ] navigating away retracts demand (0066)
- [ ] the video tile animates without smear (the page repaints every frame or the weave reads stale
      sub-rects)

**Instrumentation, and its limit.** `adb logcat -s chromium` should show
`[DisplayXR] weave: GPU-resident scratch path (no CPU readback)`; the runtime service log on device
should show the matching per-frame weave lines. Those prove the *path*, not the *picture*.

> **Human-eyeball gate.** Neither logs nor `adb exec-out screencap` can judge the weave — a capture
> shows the interlaced framebuffer, not what the lenticular does with it. Every milestone that
> claims 3D output ends with a person looking at the panel, exactly as `docs/rebase-runbook.md` §6
> part 3 requires on Windows. Device: NP02J, serial `327343950099`.

---

## Estimated new code

Per the #1056 design, roughly **350–450 lines in `components/displayxr/android`** — the Java/Kotlin
runtime connector (modelled on `RuntimeFdConnector.kt`), its JNI shim, and the fd plumbing to the GPU
process — plus the two platform backends, `displayxr_weave_client_android.cc` and
`displayxr_weave_gpu_android.cc`, mirroring the ~750/~400-line mac pair, plus the Android
display-mode controller. Call it a low four figures of new code and zero lines of new architecture.

---

## Known risks

1. **`XR_DXR_weave` spec v8 landed on runtime `main` the same day this doc was written**
   (runtime `040536b42`, released v2.8.0 2026-08-19) — the header, `xrWeaveSetScreenFlatRegionsDXR`,
   and `XrWeaveSubmitFlatRegionsDXR` all exist now, so patches 0067/0069's `weave_spec_version >= 8`
   guard passes against a current runtime. Remaining Android-specific gap: the Android weave path
   (`comp_multi_weave_android.c`) accepts flat regions but ignores them (`(void)flat_rects`) — safe,
   since v8 is advisory and hardware-only (woven pixels are bit-identical), but the panel's hardware
   3D element stays all-or-nothing on Android until the flat-region wish is wired to the Android DP's
   zone/lens channel. Runtime follow-up, not a port blocker.
2. Whether Android's `SkiaOutputDevice` reaches the weave through `MaybeWeaveOutput()` or
   `MaybeWeaveRootRenderPass()` — decides whether 0013 needs an Android arm.
3. Whether `ProduceOverlayForWeave` yields an `AHardwareBuffer` for a Graphite-Dawn-backed canvas
   SharedImage on M151. If it does not, M1 falls back to a copy and the zero-copy claim weakens.
4. The per-frame CPU stall from the missing acquire fence (M1). Bounded and understood, but it is a
   real frame-time cost until the runtime's `sync_file` follow-up lands.
5. `chrome/browser/displayxr/` is desktop-shaped in three patches now and the pattern is growing —
   every new browser-UI-aware patch adds Android work.
