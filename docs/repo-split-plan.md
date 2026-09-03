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

## Status (2026-09-03) — executed, except the public-repo strip

| # | Step | State |
|---|---|---|
| 1 | Create `displayxr-browser-pvt` (private) | **done** |
| 2 | Push full history | **done** |
| 3 | Move workflows / `patches/` / `scripts/` / internal docs | **done** |
| 4 | **Strip the public repo** | **NOT DONE — needs a human go-ahead** |
| 5 | `publish-browser-releases.yml` in the private repo | **done** (pvt #1) |
| 6 | Copy secrets + `build-box*` environments | **done**, minus `PINBUMP_TOKEN` — see below |
| 7 | Android keystore secret (browser#188) | still open |
| 8 | Update docs naming the repo | **done** (runtime `CLAUDE.md`) |
| 9 | `/dxr-release` gains a `browser` component | **done** |

Step 4 is deliberately last and deliberately not automated: deleting source from a public
repo is hard to reverse and outward-facing, so it wants a human decision, not an agent's.

**`PINBUMP_TOKEN` was retired rather than copied** (pvt #3). It was a PAT; the publish flow
now mints a `displayxr-publish-bot` App token scoped to `displayxr-runtime`, which
auto-rotates, cannot outlive its installation, and needs no manual renewal. The public repo
still holds the secret because its `pipeline.yml` still references it — both go together in
step 4.

### The "Windows build box" section above is now WRONG, in a good way

It predicted the migration's one piece of box-side work would be giving the box credentials
to read the private repo. That work **no longer exists**, because the box no longer fetches
its own source at all.

`do_rebase.{sh,ps1}` used to `codeload` a hardcoded `DisplayXR/displayxr-browser`. Left as-is
that fails two ways after the split, and the second is the expensive one:

- **Loud:** once the public repo is stripped of `patches/`, every build dies with
  "no patches under patches/".
- **Silent:** while the public repo still carries a *stale* `patches/`, a run against `main`
  **succeeds and builds the old public series** — green CI for source nobody changed.
  Anonymous `codeload` **404s** on a private repo rather than 401ing, so from the box "wrong
  repo" and "bad ref" are indistinguishable. That is what made it quiet.

The fix inverts who resolves the ref: the **runner** resolves `patch_ref` (it is the only side
holding a repo credential), archives it, and stages the zip in the artifact bucket; the box
pulls it with its instance profile. No GitHub credential reaches the box, none lands in an SSM
command's logged parameters, and **the box cannot choose a source at all** — so the silent mode
is unrepresentable rather than merely fixed. `codeload` survives only as an explicit
public-repo fallback (pvt #4 for Android, #5 for Windows).

Giving the box a credential would have fixed the *loud* failure and left the silent one intact.

### Traps found while provisioning, worth knowing before the next split

- **GitHub emits an ID-based OIDC `sub` for newer repos** (`repo:<org>@<id>/<repo>@<id>:...`).
  A role trusting only the documented name form fails `AssumeRole` with a message naming
  neither claim. Trust both forms.
- **The SSM document name is part of the permission.** Granting `ssm:SendCommand` on
  `AWS-RunPowerShellScript` and then sending `AWS-RunShellScript` yields `AccessDeniedException`
  — which reads as a missing permission, not a wrong document. Derive it from the instance.
- **Every AWS `put-*` replaces the whole document.** A bare put of one S3 lifecycle rule
  silently deleted an existing one. Read-merge-write by Sid/ID, and log what was preserved.

## Open question for legal

Chromium is predominantly BSD, but confirm nothing in the shipped configuration carries an
LGPL/MPL source-offer obligation before assuming a private fork is free of publication duties.
