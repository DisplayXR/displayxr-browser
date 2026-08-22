# Docs

- **[android-port.md](android-port.md)** — the Android weave port: design (written before
  implementation) plus an "As built" section covering what actually shipped through device bring-up
  (fd bootstrap, texture extraction, loader bundling, pre-rotation, SurfaceControl gate, runtime
  dependencies, scroll/frosted parity, known gaps).
- **[android-pitfalls.md](android-pitfalls.md)** — standing checklist of traps specific to the
  Android arm (R8/JNI, backend probing, fencing, the runtime's rig/geometry contracts). Read before
  touching `components/displayxr/android` or any `*_android.*` backend file.
- **[maintenance-policy.md](maintenance-policy.md)** — the load-bearing decision: monthly-milestone
  rebase cadence + the (mandatory) preview/security disclaimer + version-check-not-auto-update. Mirrors
  §6 of the runtime packaging plan (source of truth).
- **[rebase-runbook.md](rebase-runbook.md)** — the step-by-step monthly rebase: fetch → apply → resolve
  drift → build → **verify weave** → sign → release, with the gotchas.
- **[integration-points.md](integration-points.md)** — the enumerated file set the patch touches
  (grouped by subsystem), so a rebase conflict can only land in a known, documented hook. The reason a
  rebase is mechanical.
- **[release-and-distribution.md](release-and-distribution.md)** — the release flow (build → sign →
  GitHub Release), the website download, and the lightweight version-check-not-auto-update mechanism.
- **[remote-build.md](remote-build.md)** — build on the remote signing/build box (`$DXR_SIGN_REPO`) to
  free the local machine from the multi-hour compile; the one-time box provisioning + caveats.

Design/rationale for every hook lives in the runtime repo:
[`docs/roadmap/webxr-step-b-design.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/webxr-step-b-design.md)
§13 and
[`displayxr-browser-preview.md`](https://github.com/DisplayXR/displayxr-runtime/blob/main/docs/roadmap/displayxr-browser-preview.md).
