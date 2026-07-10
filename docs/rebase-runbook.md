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
Re-verify the series reproduces the branch exactly (working-tree-safe — uses a throwaway index):
```bash
export GIT_INDEX_FILE=/tmp/verifyidx; git read-tree "$CHROMIUM_TAG"
for p in "$REPO"/patches/*.patch; do git apply --cached --binary "$p" || { echo "FAIL $p"; break; }; done
[ "$(git write-tree)" = "$(git rev-parse displayxr-inline-3d^{tree})" ] && echo "series OK"
unset GIT_INDEX_FILE
```

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

## Known gotchas
- **Box kills long builds** (`clang-cl: error … failed due to signal`) — transient; `build.sh` retries.
- **Kill chrome before rebuilding** (it locks the DLLs / exe). **Never kill `displayxr-service`.**
- Regenerating Blink bindings (`runtime_enabled_features.json5`, IDL `.gni`) triggers a long one-time
  rebuild — expected.
