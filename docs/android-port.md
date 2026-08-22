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

---

## As built (2026-08-21)

Everything above is the **design**, written before a line of Android code existed. This section
records what bring-up on real hardware (NP02J, human-eyeballed 2026-08-20 and 2026-08-21) actually
produced, and where it diverged from the plan. It does not rewrite the sections above — read them
first for the intended shape, then this section for the correction layer. Standing traps this work
surfaced are pulled out separately into **[`docs/android-pitfalls.md`](android-pitfalls.md)**; this
section only covers what shipped and what's still open.

**Where the code lives.** None of it is in `patches/` yet. The whole Android arm — M1, M2, M3, and
the device-bring-up fixes below — exists only on a local branch on the (stopped) EC2 Linux builder,
snapshotted to `.android-port-wip.tgz` (`m2snap/`, gitignored) and mirrored off-box. Capturing it as
`patches/0075+` and opening a PR against this repo is blocked on **#122** (the 0072-0074 web#12
recapture refresh) landing first — coordinated in **#100**'s milestone tracker, which stays the
authoritative open/closed state. Treat this section as validated-on-device engineering knowledge, not
as a description of anything currently `git log`-able in this repo.

### M2 — fd bootstrap, as shipped

The mechanism matches the design's three steps, with one routing change and a lot of hardening:

- **Java connector.** `DisplayXrRuntimeConnector` reflectively loads
  `org.freedesktop.monado.ipc.Client` out of the installed runtime package and warms up on
  `PostBrowserStart`, gated on `--enable-inline-3d`. Foreign-APK reflection like this is safe under
  R8 (see below) because R8 only renames classes inside *this* APK.
- **Fd → GPU process.** The design's text preferred the Mojo route for this hop; **as shipped it goes
  the other way**: `GetAdditionalMappedFilesForChildProcess()` maps the fd into
  `base::GlobalDescriptors` under a `kAndroidDisplayXrIpcDescriptor` key, and
  `ContentSandboxHelper::PreSandboxStartup` reads it back out and `setenv`s `DXR_IPC_FD` before the
  GPU process's first OpenXR call. Android's one-bionic-libc-per-process model means `setenv` here
  genuinely works — there is no static-CRT snapshot trap like Windows has.
- **One connection per browser process**, exactly as designed: the browser opens the runtime IPC
  connection once and keeps the `Client` object alive for the process lifetime; dropping it unbinds
  the service and frees the `PRESENT_OWNER` slot.
- **Close + discard on GPU loss.** A GPU-process crash leaves the browser's dup alive (slot ownership
  and the death-link both attribute to the *connector*, not the adopter — `SO_PEERCRED` names the
  browser), so a naive reconnect leaves a ghost `PRESENT_OWNER` behind. Two ghosts exhaust the
  system-wide quota of 2 and every subsequent `xrCreateInstance` fails with
  `XR_ERROR_LIMIT_REACHED`. The shipped fix explicitly closes and discards the old `Client` before
  reconnecting.
- Device bring-up needed two more fixes before any of this could run at all: `xrInitializeLoaderKHR`
  needs a real JNI `VM`+`Context` reached through the app classloader (not `FindClass` from a native
  thread — that hits the bootstrap classloader and returns null), plus a manifest `<queries>` block
  for the runtime broker/provider on Android 11+.
- `displayxr_weave_client_android.cc` / `displayxr_weave_gpu_android.cc` are the third dispatcher arm
  patch 0052 established — same shape as the `_mac` pair, no re-architecture.

### M1 — texture extraction, as shipped

- Scratch/atlas SharedImages allocate with **`SCANOUT` usage + `kRGBA_8888`** (not BGRA — BGRA
  silently selects a non-AHB backing factory) so the backing routes to
  `AHardwareBufferImageBackingFactory`.
- **This device class fails Dawn adapter validation, so it never gets Graphite — Skia runs Ganesh.**
  M1's first cut assumed Graphite-first and dereferenced a null recorder; the shipped extraction and
  fence code branches on the actual backend (`gr_context_type`) rather than assuming one.
- `SetCleared()` is called explicitly on the staging SharedImage after each write. `ScopedWriteAccess`
  does not auto-mark the cleared-state gate, and an uncleared read is silently refused
  (`access == NULL`, no per-frame log). The macOS path has the identical latent bug
  (`EnsureScratchClearedMac`) — filed as a known issue there too, not fixed here.
- AHB extraction reads through `GetAHardwareBufferFenceSync()->buffer()`, never the base
  `OverlayImageRepresentation::GetAHardwareBuffer()` (which is `NOTREACHED()` on this path).
- **No provider-side blit, as designed**: the staging AHB *is* the weave input, drawn directly at
  window position — there is no extra copy into a second buffer before `xrWeaveSubmitDXR`.
- **Same-frame draw-back:** the woven output `AHardwareBuffer` is imported straight back as a
  SharedImage and drawn in the same frame's compositing path — `XrWeaveOutputDXR::weavedTexture` is
  cached and only re-imported when the runtime hands back a new one (first submit, or a reallocation
  on resize), with the old buffer `AHardwareBuffer_release()`d at that point.
- Fencing follows the design's CPU-wait branch: `gr->submit(GrSyncCpu::kYes)` (the Ganesh arm) before
  every `xrWeaveSubmitDXR`, since the runtime has no acquire fence yet on this platform.

### Loader bundling — Khronos loader only, no vendored runtime

The APK bundles the **Khronos `openxr_loader_for_android` AAR (pinned 1.1.62)** as arm64
`libopenxr_loader.so` — nothing else OpenXR-shaped ships in the APK. There is deliberately **no
vendored runtime `.so` and no import library**, unlike the Windows lane's patch 0001. The reason is
the **git-tag gate**: `ipc_client_check_git_tag()` `strncmp`s the client library's compiled-in
`u_git_tag` against the running `displayxr-service`'s, and fails `xrCreateInstance` on any mismatch.
Bundling a runtime `.so` in the browser APK would fix that `.so`'s tag at build time and break the
gate against whatever runtime happens to be installed on the device. Instead, the loader resolves and
loads the **device's installed runtime package's** `.so` at runtime, exactly as any other OpenXR app
on the device does — so the browser always speaks to whatever runtime the device actually has,
tag-matched by construction.

### R8 / JNI bridge

Release `chrome_public_apk` builds run through R8, which renames this APK's own classes/methods
(confirmable in the R8 mapping file — a StrictMode stack showing `.a`/`.b` is the tell). Any
by-name Java reflection on **our own** classes silently breaks. The fix is a generated-JNI
(`@CalledByNative`) bridge for anything in-APK that needs to be reached from native code or looked up
by name, instead of reflection. Reflection into the runtime's `org.freedesktop.monado.ipc.Client`
(a **foreign** APK's class, reached via `createPackageContext`) is unaffected — R8 cannot rename code
it doesn't own — and stays the mechanism M2 uses for the connector.

### Pre-rotation: the kLogic opt-in

First light shipped with a 90° bug: the browser rendered landscape, but woven elements came out
portrait. Root cause: Android surface pre-rotation — Viz renders the root pass in the panel's
**natural** (portrait, on this device) orientation with a transform hint attached, and
`Reshape()` historically ignored that hint on the paths this port touches, so the staging buffer and
published geometry ended up portrait (1540×2560) under a landscape browser. The shipped fix opts
`SkiaOutputDeviceBufferQueue` into `orientation_mode = kLogic` whenever `--enable-inline-3d` is set,
so Viz rotates the root pass itself before the weave ever sees it. (Android-Vulkan already ships
`kLogic` by default; the GL device was the only site still using `kHardware`.) **This sidesteps the
bug rather than fixing it** — a durable transform-aware path through `Reshape()` is still a TODO (see
Known gaps). If a genuinely non-identity transform hint ever reaches the weave code under this
opt-in, the existing latched-error path fires rather than silently mis-rendering.

### SurfaceControl gate (the 0041 analogue)

Design risk #2 asked whether Android's `SkiaOutputDevice` reaches the weave through
`MaybeWeaveOutput()` or `MaybeWeaveRootRenderPass()`; bring-up touched
`SkiaOutputDeviceBufferQueue` machinery, which suggests the buffer-queue/GL entry is live on this
device class, but the question was never formally closed against source — treat it as still open.

What *is* settled: SurfaceControl / overlay promotion is the Android hazard 0041 predicted. A
promoted WebGL canvas quad — the SDK's only WebGL canvases; video paints into a plain 2D canvas —
leaves the root render pass entirely, so `WeaveCompositedSurface()` finds a hole where the tile
should be and the keep-tile gate falls back to showing the raw, unwoven side-by-side source. This was
first proven with the runtime feature disabled ad hoc
(`--disable-features=AndroidSurfaceControl`); the durable fix mirrors 0041 exactly — a
force-disable of overlay promotion in `ChromeMainDelegate::BasicStartupComplete()` under
`--enable-inline-3d`, landed in the 2026-08-21 Windows-parity round.

### Rig locate over mojo to the GPU session — and why not headless

The three.js live-scene tile needs render-ready stereo views (`LocateViewsForRect`), which on
Windows the browser process answers from its **own** present-owner session. Android has no such
second session — per M2, there is exactly **one** runtime IPC connection for the whole browser,
owned by the browser process and adopted by the GPU process; publishing a second, independent
connection is refused by the runtime (one connection per process). So the rig-locate query is instead
**relayed over the existing `displayxr_weave.mojom` pipe to the GPU process's weave session** — the
only OpenXR session that exists on Android — and answered there.

The alternative that was explicitly rejected: standing up a local `XR_MND_headless` session in the
browser to answer rig queries without touching the GPU process. Headless sessions are **bridge
relays** — their rig/zone descriptors are inert and their reported eyes are raw/verbatim, not
DP-tracked (this is now standing knowledge, see `docs/android-pitfalls.md` item 13). Answering a
scene's rig query from a headless session would silently produce plausible-looking but wrong
geometry — the exact same failure class runtime PR #1118 later had to fix generally for weave-only
sessions (see below). Routing the query to the real weave session avoids reproducing that bug
locally. The Android arm also swaps `XR_KHR_win32_convert_performance_counter_time` for
`XR_KHR_convert_timespec_time` (design doc's "0036, the one-liner") to supply the `displayTime` the
rig query needs.

### Runtime-side dependencies (#1116 / #1118)

Wiring the rig locate through the real weave session exposed a runtime gap, not a browser bug.
**A weave-only present-owner session — no swapchain, no `session_render` — got no window metrics at
all**, because `multi_compositor_get_window_metrics()` gated every one of its branches (vendor DP,
Win32 client rect, Android present-target extent) on `session_render.initialized`. Silently, that made
every such session read as "owns the whole panel": the device-px `XrDisplayZoneDXR` rect the app had
correctly chained under `XrDisplayRigDXR` got dropped at the zone gate, and the Kooima frustum was
built display-scoped over the panel's **natural** (portrait) orientation instead of the app's
landscape window — human-verified wrong aspect *and* wrong frustum centre on the NP02J. Filed as
runtime **#1116**.

The fix landed as two commits on runtime **PR #1118** (open as of this writing, not yet merged; the
verified device pass ran against runtime `9c83df864` / `v1.21.1-785-g9c83df864`):

1. A fourth, last-priority branch in `get_window_metrics()` that reads `mc->weave.win_*` — the rect
   `xrWeaveBindWindow2DXR` / `xrWeaveSetWindowGeometryDXR` already publishes, previously consumed only
   by the DP's per-window phase slot. It runs strictly after the vendor-DP, Win32-HWND, and
   Android-present-target branches, so any session with a richer geometry source is untouched; this
   only fills the hole none of the others can reach. It also transposes the panel baseline when the
   published rect overflows the natural ordering, on the theory that a window is always a sub-rect of
   its panel, so an overflow proves the panel is being held rotated. macOS's
   `comp_multi_weave_set_window_geometry()` was changed to **store** the rect instead of discarding
   it, closing the same hole there even though nothing yet reads it back into a phase.
2. Render-less weave sessions now get **DP-tracked eyes** from `mc->weave.dp` in
   `multi_compositor_get_predicted_eye_positions`, instead of falling back to nominal/static eyes. The
   nominal fallback was silently eating parallax while the weave channel itself was tracking
   correctly — the tell that caught it: the weave steered with head movement, but no parallax
   appeared. This is what produced the confirmed "true head-tracked stereo with correct zone Kooima
   and parallax" result on 2026-08-21.

### Scroll / frosted / flat-region parity work

The samples-suite pass surfaced the same defect family the Windows lane hit under `fix/12`
(patches 0072-0074, web#12): 2D page elements occasionally got woven during scroll. The
Windows-parity round (2026-08-21) ported the fix forward:

- Scroll protections: 0072-0074 hand-merged onto the Android branch, plus the `#87`/`#99` protection
  paths un-gated from `IS_WIN` so they run on Android too. Fixed an Android-specific per-rect draw-back
  stamping bug (a rect was being stamped with `kSrc` into the wrong destination) by tracking a
  distinct `drawn_rect`. Tightened the rect union to cardinality + greedy join.
- Frosted/exclusion rects: a per-rect blit was *deleting* frosted-glass regions instead of subtracting
  them from the woven content; fixed by subtracting them with a `kDifference` clip.
- Flat-region wish: `SetBatchWish` now wires to the runtime's weave spec v8
  (`xrWeaveSetScreenFlatRegionsDXR` / `XrWeaveSubmitFlatRegionsDXR`), closing design doc Known Risk #1
  (spec v8 landed on runtime `main` the same day the design doc was written). The Android DP path
  (`comp_multi_weave_android.c`) accepts the wish but still only advisory-no-ops it — wiring the wish
  through to an actual per-zone hardware lens change on Android remains the runtime follow-up the
  design doc already called out, unchanged by this work.
- A `--inline-3d-dp-overlay` opt-in flag was added for a "v4 DP overlay atlas" path, but the
  overlay-atlas *mechanism* itself was retired on every platform back in Phase 2 (0063-0065,
  plane-split occlusion). Android already used the over-plane mechanism before this flag existed, so
  treat the flag as legacy/inert, not load-bearing.

### Known gaps

1. **One-frame scroll lag.** Woven content lags real content by one frame during scroll; the fix in
   flight ports Windows patch 0023's same-frame sync weave ordering to Android.
2. **Durable pre-rotation transform path.** The `kLogic` opt-in above avoids the 90° bug by forcing an
   orientation mode; it does not make `Reshape()` transform-aware. A real fix belongs upstream of the
   opt-in.
3. **Display-mode Android arm.** `chrome/browser/displayxr/displayxr_display_mode_controller.*`
   (0054/0066/0069 — foreground-tab demand, navigation retraction, popup occluders) is built entirely
   on desktop types (`BrowserWindowInterface`, `views::Widget`) and is excluded from
   `chrome_public_apk`'s source list rather than ported. A parallel controller on
   `TabModelSelector`/`TabModel` observers over JNI, expressing the same three edges, has not been
   built — foreground-tab demand was only exercised manually during the samples-suite test, not
   through a real per-tab controller.
4. **Freeform geometry feed.** Geometry publication was proven against the samples-suite's
   full-screen/single-window shape. The general Android multi-window / freeform case (see
   `XR_DXR_android_surface_binding` in the runtime repo) is unexercised here.
5. **L11 sync coupling.** A pending vendor CNSDK GPU-sync change (a semaphore-pair contract replacing
   the current CPU fence wait) will change the runtime's weave-completion contract. When it lands, the
   runtime's sync-return-is-completion contract for Android weave *and* this port's Ganesh
   `submit(SyncToCpu)` fencing (M1) need to be revisited together — filed as a coordinated follow-up,
   not yet scheduled.
