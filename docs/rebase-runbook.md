# Monthly rebase runbook

The maintenance commitment (see [maintenance-policy.md](maintenance-policy.md)) is a **~monthly rebase
onto each new Chrome stable milestone**. Because the patch touches a small, enumerated file set
([integration-points.md](integration-points.md)), a rebase is mechanical: fetch → apply → resolve any
drift → build → verify weave → sign → release. Windows / D3D11 + DirectComposition only.

## 0. Prereqs (on the build box)
- depot_tools at `$DEPOT_TOOLS`, on PATH; `DEPOT_TOOLS_WIN_TOOLCHAIN=0`; VS 2022 (C++), Windows SDK.
- The DisplayXR **runtime** + a **display plug-in** installed & registered (the weave no-ops without
  them, so verification needs them). `displayxr-service.exe` running.
- `$DXR_SIGN_REPO` set for signing (e.g. from `displayxr-runtime/.env.local`). Optional — unsigned still
  ships (with a warning).

## 1. Pick the new pin
Find the latest **stable** milestone tag on chromiumdash (e.g. `151.0.xxxx.yy`). Edit
`scripts/config.env` → `CHROMIUM_TAG`.

## 2. Fetch the new milestone
```bash
scripts/fetch.sh          # git fetch --tags; checkout $CHROMIUM_TAG; gclient sync -D; runhooks
```

## 3. Re-apply the patch series onto the new tag
```bash
cd "$CHROMIUM_SRC"
git checkout "$CHROMIUM_TAG" && git checkout -B displayxr-inline-3d
git am --3way patches/*.patch
```
- **Clean apply?** → skip to step 4.
- **Conflict?** `git am` stops on the offending patch. The conflict is in a ⚠ file from
  integration-points.md. Re-read that hook's role + the matching `webxr-step-b-design.md` §13
  subsection, resolve against the new milestone's code, `git add -A`, `git am --continue`.
- **A patch went fully upstream / no longer applies at all?** Drop it (`git am --skip`) only if its
  change is genuinely absorbed; otherwise port it by hand.

## 4. Regenerate the patch series (capture the resolved rebase)
```bash
git format-patch --binary --no-signature -o "$REPO/patches" "$CHROMIUM_TAG"..displayxr-inline-3d
```
Verify the capture with `scripts/verify-series.sh` (run it from `$CHROMIUM_SRC`, or pass `--src`;
it reads `$CHROMIUM_TAG` from `scripts/config.env` by default):
```bash
"$REPO"/scripts/verify-series.sh --tag "$CHROMIUM_TAG" --branch displayxr-inline-3d
```
It runs **two independent checks — both must pass**, not just the first:

1. **Reproduction** (the original working-tree-safe check, now scripted): the series applied via
   `git apply --cached --binary` onto a throwaway index seeded from `$CHROMIUM_TAG` must produce
   `displayxr-inline-3d`'s tree exactly. This catches a bad `format-patch` capture (dropped,
   reordered, or truncated patch) — but **nothing else**, and per browser#106 it is easy to never
   actually run: it's a manual copy/paste block, not a CI-enforced step, which is exactly how a
   drifted series (below) shipped without anyone noticing.

2. **Fresh-clone apply gate** (browser#106, new): the series applied with a **plain**
   `git am --keep-non-patch --no-3way` onto a `git worktree` of `$CHROMIUM_TAG` must *also*
   produce that same tree. This is the check that matters, because it reproduces what a genuine
   fresh clone sees. `--3way` (used for the *rebase* itself in step 3, and by `do_rebase.ps1` on
   the build box) is fine for resolving real conflicts, but on a conflict it will silently
   reconstruct a fake ancestor from whatever blob the patch's SHA1 line names *if that blob
   happens to be present in the local object DB* — e.g. because this checkout has built
   `displayxr-inline-3d` before, or because the fork branch's own history is right there. That
   content-merges the patch against history a fresh clone doesn't have, masking internal series
   drift (a later patch's declared pre-image no longer matches what the earlier patches in the
   series actually produce). Plain `am` has no such fallback — it applies textually, so a worktree
   of the tag reproduces fresh-clone behavior exactly (cross-checked against a true fresh clone in
   browser#106: plain `am` failed identically there). This is what bit us at patch 0022: 0022's
   3-line context predated an assignment path patches 0001–0021 had already added, `--3way` on the
   fork's own box quietly content-merged it using history only that box had, and every fresh clone
   — a new contributor, a new build box, the Android-port builder — hit a hard apply failure.

**The tell:** if you ever see `sha1 information is lacking or useless` from this gate, the gate
did not run as designed — that error is `--3way` telling you it just built a fake ancestor from
local history to paper over a conflict. It means investigate immediately, don't retry with
`--3way` and move on. The gate's own failure mode instead reads `patch failed: <file>:<line>` /
`patch does not apply` — that's the real, unmasked signal that the series has drifted; recapture
from the fork branch tip (steps 1-4 above) rather than hand-splicing the offending patch.

## 5. Build (official static)
```bash
scripts/build.sh          # brand + gn gen out/Official + autoninja chrome (retry loop; multi-hour)
```

## 6. Verify the weave (MANDATORY — a rebase can silently perturb the GPU path)
Launch the official `chrome.exe` **Medium-integrity** (`explorer.exe run.bat`, never elevated) with:
```
--enable-inline-3d --enable-blink-features=DisplayXRInline3D
--disable-features=CalculateNativeWinOcclusion,DelegatedCompositing
--enable-logging --log-file=… --v=1 --user-data-dir=<fresh>
```
on an inline-3d page (a `displayxr-web` sample, or `b4_single.html`). **Three-part success:**
1. **chrome log** shows `[DisplayXR] weave: GPU-resident scratch path (no CPU readback)` + `canvas tex …`.
   ⚠ The eyeball looks identical on the `WeavePixels` fallback — the marker is the *only* proof the
   zero-copy path ran. A `zero-copy fell back: <reason>` VLOG(1) means investigate.
2. **service log** (`%LOCALAPPDATA%\DisplayXR\DisplayXR_displayxr-service.*.log`) shows
   `[leia_dp_d3d11_process_atlas] weave: target=… vp=(…)` — **grep by timestamp > launch** (prior
   sessions' dying weaves are false positives) — with **zero** `0x80070057`.
3. **eyeball:** glasses-free 3D on the canvas rect, flat 2D around it (needs face tracking — the DP is
   2D↔3D tracking-gated).

## 7. Package + sign + release
```bash
scripts/package.sh                        # dist/DisplayXR-Browser/
scripts/sign.sh dist/DisplayXR-Browser    # EV-sign via $DXR_SIGN_REPO (folder-sign path)
```
Then the P2 installer + P3 GitHub Release (see the packaging plan). Bump the version-check tag so
existing installs see the new preview.

## Building on the box (CI lane)

`build-box.yml`'s rebase step drives `do_rebase.ps1` on the AWS box, which **syncs `patches/` from
this repo** (`git fetch` of `patch_ref`, default the CI commit's SHA) into `C:\build\patches` before
applying it. So whatever series is committed here is what the box builds — including a series that
has *grown*, which is the case that used to be impossible: nothing ever shipped `patches/` to the
box, `C:\build\patches` was populated by hand, and the series is far too large (~3.5 MB) to stage
inline over SSM RunCommand.

To build a **branch** (e.g. to verify a new patch on hardware), dispatch `build-box.yml` with:
- `chromium_tag` = the current pin from `scripts/config.env` — the rebase step is skipped when this
  is blank, and the patch sync lives inside it;
- `patch_ref` = your branch name or SHA.

The box is **stopped before and after** by the workflow (`if: always()`), so a failed run cannot
leave the instance billing.

## Known gotchas
- **Box kills long builds** (`clang-cl: error … failed due to signal`) — transient; `build.sh` retries.
- **Kill chrome before rebuilding** (it locks the DLLs / exe). **Never kill `displayxr-service`.**
- Regenerating Blink bindings (`runtime_enabled_features.json5`, IDL `.gni`) triggers a long one-time
  rebuild — expected.
