# Android port pitfalls

Standing checklist for anyone touching the Android weave arm (`components/displayxr/android`,
`chrome/browser/displayxr/*_android.*`, the Java runtime connector). Distilled from the device
bring-up loop that produced first light and the samples-suite pass on the NP02J (2026-08-20 /
2026-08-21) — see **[`docs/android-port.md`](android-port.md) § As built** for the fixes these
traps produced. Each item below cost a real device round before it was understood; read this before
writing Android-arm code, not after debugging the same failure again.

## Platform / process

1. **R8 obfuscates release `chrome_public_apk` — no by-name reflection on our own classes.**
   Release builds rename this APK's classes/methods (a StrictMode stack showing `.a`/`.b` is the
   tell; check the R8 mapping file if unsure). Use generated-JNI (`@CalledByNative`) for anything
   in-APK. Reflection into a **foreign** APK's classes — e.g. the runtime's
   `org.freedesktop.monado.ipc.Client` via `createPackageContext` — is unaffected, since R8 can't
   rename code it doesn't own.
2. **JNI `FindClass` from a native thread hits the bootstrap classloader, not the app's.** It
   returns null for app classes. Route class lookups through `base::android::GetClass` / jni_zero,
   not raw `FindClass`.
3. **`xrInitializeLoaderKHR` needs a real VM + Context.** `XrLoaderInitInfoAndroidKHR` must carry a
   genuine application `Context` reached through the app classloader, and the manifest needs a
   `<queries>` block for the runtime broker/provider on Android 11+. Check the `XrResult` — don't
   assume success and proceed.
4. **One runtime IPC connection per process.** The runtime refuses (`-2`) a second, independently
   opened connection from the same logical app. A cross-process need (browser ↔ GPU) is not "open
   twice" — it's mojo relaying the one connection's session/queries, or a deliberate fd handoff (see
   `docs/android-port.md`'s M2 fd bootstrap).
5. **A GPU-process crash leaves the browser's connection alive.** Slot ownership and the death-link
   both attribute to the *connector* process (`SO_PEERCRED` names the browser, not the adopter), so a
   naive reconnect leaves a ghost `PRESENT_OWNER` behind. The quota is 2 system-wide — two ghosts and
   every subsequent `xrCreateInstance` fails `XR_ERROR_LIMIT_REACHED`. Close and discard the old
   client object before reconnecting.

## Graphics

6. **Probe the backend before writing backend-specific code.** Some device classes fail Dawn adapter
   validation and never get Graphite — Skia falls back to Ganesh-GL. Any `graphite_*` member may be
   null; every backend-flavored call needs a Ganesh arm too. One `adb logcat` check settles this
   before you write a line against an assumed backend.
7. **The SharedImage cleared-state gate is not automatic.** A read from an uncleared image is
   silently refused (`access == NULL`, no per-frame log to notice it by). `ScopedWriteAccess` does
   **not** mark the image cleared — call `SetCleared()` explicitly at every write site, the way the
   rest of `skia_output_surface_impl_on_gpu.cc` already does.
8. **AHardwareBuffer extraction has one correct entry point.** The base
   `OverlayImageRepresentation::GetAHardwareBuffer()` is `NOTREACHED()` — use
   `GetAHardwareBufferFenceSync()->buffer()` and keep the scoped access alive across the submit. AHB
   backing additionally requires `SCANOUT` usage **and** `kRGBA_8888` — `BGRA` silently selects a
   non-AHB backing factory with no error.
9. **Surface pre-rotation is real and easy to miss.** Viz renders the root pass in the panel's
   *natural* orientation with a transform hint attached; a naive `Reshape()` can ignore that hint,
   producing correctly-rendered-but-wrongly-oriented output (a 90° bug on a portrait-native panel
   under a landscape browser). Forcing `orientation_mode = kLogic` sidesteps it; a durable
   transform-aware path through `Reshape()` is still open — don't assume the sidestep is the fix.
10. **Fence before you submit, not after you flush.** The runtime has no acquire fence on this
    platform — the caller must be GPU-complete before `xrWeaveSubmitDXR`. On Ganesh that's
    `gr->submit(GrSyncCpu::kYes)`; a bare `flush()` is not sufficient. The Graphite equivalent is
    guarded on the *recorder*, not the context — don't assume the two are interchangeable.

## Contracts (the runtime owns the math — don't re-derive it)

11. **`XR_DXR_view_rig` views are render-ready.** Kooima projection and metric-to-virtual conversion
    are already done by the runtime. Pass the views through verbatim — zero client-side projection
    math. The full extension set a rig query needs: `view_rig` + `display_zones` + `local_3d_zone` +
    a timespec-time-convert extension (there is no legal `displayTime` without one).
12. **State units and spaces at every interface, and don't assume they match the last one you
    touched.** Zone rects are device pixels, positioned window-relative against the bound window
    geometry; Blink hands you CSS/logical pixels. Convert exactly at the boundary, comment the units
    in any new field you add, and don't propagate an assumption from one platform's plumbing to
    another's without re-checking.
13. **Headless (`XR_MND_headless`) sessions are bridge relays, not general-purpose query sessions.**
    Their rig/zone descriptors are inert and their reported eyes are raw/verbatim, not DP-tracked.
    Never stand one up to answer a rig or eye-position query — the runtime's window-metrics gap
    (`docs/android-port.md`'s #1116/#1118 section) is exactly what this class of shortcut produces:
    plausible-looking but silently wrong geometry.
14. **Window geometry is required on Android, not optional.** There is no HWND and no move event —
    publish `XrWeaveWindowGeometryDXR` (screen-space device px) from the real UI thread and re-bind
    on move, resize, and rotation. The runtime dedupes, so republishing every frame is safe; under-
    publishing is not.
15. **No per-frame `U_LOG_W`.** Runtime-wide convention, and it bites hardest on Android where a
    logcat firehose during a scroll or a submit-rate loop is easy to trigger by accident. Latch every
    error with a static bool or `LOG_FIRST_N` — one line per session, not per frame.

## Process discipline

16. **Before implementing against an assumption, find the one-command check that answers it.** A
    single `adb logcat` grep or a one-line static check is cheaper than a wrong implementation round.
    Do that first and report what it actually said, not what you expected it to say.
17. **After any runtime install, verify which display processor is actually active.** The vendor
    plug-in's absence is *silent* — a fallback simulation display processor fakes nothing loudly, so
    "it built and ran" is not evidence the real vendor path is under test. Check for the
    vendor-specific libraries in the installed APK and the vendor-identifying log line before trusting
    a result. The same discipline applies in reverse: before accepting a claim that invalidates your
    own result, run the same cheap check yourself rather than taking the claim on faith.
18. **A design hypothesis is a lead, not a conclusion.** Treat any stated assumption about how a
    platform behaves — including the ones in `docs/android-port.md`'s design sections — as something
    to refute or confirm against source or a device check, not something to build on unverified. Two
    device rounds on this port were spent on exactly this: implementing against a design assumption
    that a cheap check would have overturned first.
