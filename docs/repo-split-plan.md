# Browser repo split — private dev, public releases

Mirrors the shell's `displayxr-shell-pvt` → `displayxr-shell-releases` pattern.

## Why

The public repo buys nothing measurable and costs something concrete:

| | displayxr-browser | displayxr-runtime |
|---|---|---|
| forks | **0** | 4 |
| stars | **0** | 2 |
| external PR authors | **none** (99/99 in-house) | 1 (`leaiss`, 3 PRs) |

That isn't a marketing failure, it's structural: contributing to a Chromium fork means a
multi-hour build on a dedicated box, depot_tools, and a 100+ patch series rebased onto Chrome
stable monthly. Nobody drive-by contributes to that. The runtime, by contrast, is a normal
CMake project implementing a published standard — which is exactly where the forks are.

The openness argument for DisplayXR is about the **runtime** being neutral infrastructure that
OEMs can standardise on without lock-in fear. It does not transfer to a browser, which is a
product and a demonstration vehicle. No OEM adoption decision turns on whether our Chromium
fork is public.

Concrete cost of the status quo: the **Android release keystore** (browser#188) has to live
somewhere. In a public repo the exfiltration surface is every branch-push; in a private one it
collapses to people who already have write access to everything.

## Shape

| repo | visibility | contents |
|---|---|---|
| `displayxr-browser-pvt` | **private, new** | `patches/`, `scripts/`, `docs/`, all build lanes, the Android keystore secret |
| `displayxr-browser` | **public, existing — KEEPS ITS NAME** | releases + assets, user-facing issues, the public-safe docs |

**The public repo keeps its current name, and that is load-bearing.** Three things resolve
against `DisplayXR/displayxr-browser` today and would break on a rename:
- `versions.json[browser]` (the pin, `preview-X.Y.Z`)
- `install-android-bundle.sh --links`, which resolves release assets by that repo name
- the install instructions already sent to testers, which carry literal asset URLs

So the **new** repo is the private one. Nothing user-facing moves.

## Pin handling (the part most likely to break silently)

1. `versions.json[browser]` stays `preview-X.Y.Z`. The runtime's bump validator has a
   per-field tag-shape carve-out for exactly this — do not "normalise" it to `vX.Y.Z`.
2. `browser` remains **opt-in** in the orchestrator (`--with browser`), because the preview is
   rebased monthly onto Chrome stable but not patched to Chrome's mid-cycle security cadence.
3. The `versions-bump` dispatch currently fires from the browser repo's `release.sh`. After the
   split it fires from the **private** repo's publish workflow, using a `displayxr-publish-bot`
   token scoped to `displayxr-runtime` — same as the shell's second token mint.
4. `install-android-bundle.sh`'s browser fallback (scan back for the newest release carrying an
   APK) is unaffected: it reads the public repo, which still holds every release.

## Publish flow (mirrors `publish-shell-releases.yml`)

On a `preview-*` tag in the private repo:
1. Build (Windows installer on the EC2 Windows box; Android APK on the Linux box).
2. Sign — Windows via `LeiaInc/codesign-runner` (Wibu dongle, hardware-bound, stays there);
   Android via `apksigner` with the keystore secret, which needs no dongle and so does **not**
   need the signing box.
3. Mint a `displayxr-publish-bot` token scoped to `displayxr-browser`, create the release there,
   upload assets.
4. Mint a second token scoped to `displayxr-runtime`, dispatch `versions-bump` with
   `field=browser tag=preview-X.Y.Z`.

## Migration steps

1. Create `displayxr-browser-pvt` (private, empty).
2. Push the full history to it. History is ours, contains no third-party contributions.
3. Move `.github/workflows/`, `patches/`, `scripts/`, internal `docs/` to the private repo.
4. Strip the public repo to: README, public-safe docs, issue templates, releases. Keep issues
   open — user-facing bug reports belong there, like `displayxr-shell-releases`.
5. Port `publish-shell-releases.yml` → `publish-browser-releases.yml` in the private repo.
6. Copy secrets/variables to the private repo: `DISPLAYXR_APP_ID`, `DISPLAYXR_APP_PRIVATE_KEY`,
   `AWS_BUILD_ROLE_ARN`, `AWS_ANDROID_BUILD_ROLE_ARN`, `AWS_ANDROID_BUILD_INSTANCE_ID`,
   `DXR_SIGN_REPO`, `CODESIGN_TOKEN`, `PINBUMP_TOKEN`, and the `build-box*` environments.
7. Add the Android keystore secret to the private repo (new, browser#188).
8. Update the docs that name the repo: runtime `CLAUDE.md` repo table, `docs/README.md`.
9. Update `/dxr-release`: add a `browser` row to the component→config map
   (`REPO=displayxr-browser-pvt`, `FIELD=browser`, `REL_REPO=displayxr-browser`), since the
   browser currently releases through its own `pipeline.yml` and is documented as *not* using
   that skill.

## Windows build box

The box itself does not move — it is addressed by instance id from CI, and the workflows that
drive it are what relocate. After the split its `patches/`-sync step must pull from the private
repo, so its checkout needs credentials that can read `displayxr-browser-pvt`. **That is the
one piece of box-side work this migration creates.**

## Not doing

- Not renaming the public repo (breaks the pin, the links, and instructions already sent).
- Not moving `displayxr-web` — the inline-3D API, spec and samples stay public. That is what a
  developer building *for* the browser needs; the patch series is what a competitor building a
  rival browser would want.
- Not making the runtime private. The neutrality argument genuinely applies there.

## Open question for legal

Chromium is predominantly BSD, but confirm nothing in the shipped configuration carries an
LGPL/MPL source-offer obligation before assuming a private fork is free of publication duties.
