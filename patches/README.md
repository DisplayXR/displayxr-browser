# Patch series — inline-3D over Chromium `150.0.7871.24`

`git format-patch --binary` of the `displayxr-inline-3d` fork over the pinned stable tag
`150.0.7871.24` (M150). **15 commits, 117 files** (~30 are the vendored OpenXR SDK; the real
integration surface is ~87 files — see [../docs/integration-points.md](../docs/integration-points.md)).

Apply with `git am --3way patches/*.patch` onto a fresh checkout of the tag (or just run
`scripts/build.sh`). Verified to reproduce the fork branch **exactly** (identical tree hash).

The series is roughly chronological by build phase (B2 browser-process weave client → B2c real-canvas
weave → B3 JS surface + head-tracked off-axis session → B4 chrome port + CEF sub-rect model → B4c retire
the launch flags → B4d GPU-resident zero-copy weave). On each monthly rebase this series is regenerated
against the new milestone tag (see [../docs/rebase-runbook.md](../docs/rebase-runbook.md) §4).
