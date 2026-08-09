# Weave capture harness (browser side)

The instrumentation that found browser#73's root cause — single-frame pixel dumps of the
weave composition stages, armed by a trigger file so one touch captures exactly one frame.
Kept here as a REFERENCE, deliberately **outside `patches/`** (everything in `patches/` is
applied to every build; this must never ship).

## What it captures (per trigger)

| dump | stage |
|---|---|
| `%TEMP%\dxr73_canvas.bmp` | the matched canvas resource, isolated (full image, drawn kSrc before the backdrop overwrites the scratch — restoration is free) |
| `%TEMP%\dxr73_backdrop.bmp` | the scratch after the browser#30 backdrop pre-blend |
| `%TEMP%\dxr73_scratch.bmp` | the scratch after the canvas draw = what becomes the weave input |

plus an **unthrottled** `[DXR73-DUMP]` log line with the frame's exact rect / quad_rect / uv /
image dims / src / dst — so pixels and numbers are provably from the same frame.

Arm with: `type nul > %TEMP%\dxr_browser_dump_trigger` (consumed on first sight).
The runtime-side twin (`%TEMP%\dxr_weave_dump_trigger` → weave input / SBS atlas / woven
output PNGs) lives in `displayxr-runtime` — see `src/xrt/compositor/d3d11_service/`
(`dxr_diag_dump_tex`, from the same investigation).

## Operational requirements (each cost real time to learn)

- **`--no-sandbox`** — the GPU sandbox blocks the `%TEMP%` writes; without it the dumps
  silently never appear.
- **`--enable-logging --v=1`** — the probe lines are VLOG(1).
- Raw **BMP** output via raw win32 IO: viz/service links no image codec, and base's
  blocking-IO checks don't apply to raw `CreateFileA`.
- Readback uses the CPU-fallback's own pattern (`asyncRescaleAndReadPixelsAndSubmit` under
  Graphite, `SkSurface::readPixels` under Ganesh) — copy that call shape, don't invent one.
- `-Werror` traps: `\d` in a string literal is an unknown-escape ERROR; raw pointer row
  walks need `UNSAFE_TODO(...)`.

## Analysis one-liners that did the work

- **Clamp vs content vs stretch:** per-column vertical std over the artifact region.
  Exactly 0.00 = one replicated row (texture clamp). Small-but-nonzero = stretched texture.
  Large = real content.
- **Truncation boundary:** first row (scanning up from the bottom) that differs from the
  bottom row. `start == physical_h − src_offset` nails the physical texture height.
- Compare same-instant dumps only — the canvas resource is **live** (two draws in one
  compositor pass returned different content); cross-frame pixel comparisons lie, and the
  cube in the sample rotates.

## The patch (`.ref`)

`0056-…​.patch.ref` is the exact diagnostic used in the #73 hunt, generated against the
**pre-fix** series (its context lines predate patch 0055's final form). It will not apply
cleanly to current trees — rebase the hunks by hand; they are small and the anchors are
commented. The commit message on the patch documents the evidence it produced.

Full investigation: https://github.com/DisplayXR/displayxr-browser/issues/73
