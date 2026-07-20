# Security-rebase automation — the path from Preview to a maintained 1.0

## Why this exists

The DisplayXR Browser ships as a **Developer Preview** for exactly one reason: the
[maintenance policy](maintenance-policy.md) commits only to a ~monthly rebase onto Chrome
*stable milestones*, not to Chrome's ~1–2-week security cadence — hence the mandatory
"don't use it for sensitive browsing" disclaimer. Nothing about the *feature set* blocks a real
release; the security-maintenance commitment does.

This document scopes the automation that would let us **credibly drop that disclaimer**: rebase the
inline-3D patch series onto **every Chrome stable dot-release** (and emergency 0-day drops), build,
gate, sign, and publish — with a human in the loop only when a rebase conflicts or touches the weave.
It is the enabling work for a **"1.0 — Public Release: security-maintained, Windows, no DRM"** tier
(DRM is confirmed absent today — the build is chromium-branded with no Widevine CDM — so a non-DRM
1.0 is the honest current state, not a regression).

> **Scope boundary.** This covers *producing* a patched build on cadence. It does **not** cover
> *delivering* it to installed browsers — that is **auto-update**, a separate hard requirement for
> the security commitment to actually protect users (today we only surface a "new version → download"
> prompt). Auto-update is tracked separately; a security-rebase pipeline that publishes into a void
> no one auto-installs is necessary but not sufficient.

## Infrastructure we already have (and the one trap)

| Capability | Where it lives | Status |
|---|---|---|
| Fetch Chromium@tag → apply `patches/` → `gn gen` → `autoninja` Official | **AWS EC2 build box** (`do_official18.ps1` via `schtasks`, checkout at `C:/cr/src`) | Working; **manual**, box is **stop-by-default** |
| First-party inner + outer signing | **Leia box** `sr_build_physical_box_2` via `sign-artifact` (`scripts/sign.sh` → `sign-hook.sh`) | Working; validated on 0.1.4 |
| Installer | `installer/build_installer.sh` + NSIS | Working |
| Publish + release notes | `scripts/release.sh` → GitHub Release | Working |
| Chromium pin | `scripts/config.env` `CHROMIUM_TAG` | — |
| Rebase-fragile file set | [`integration-points.md`](integration-points.md) (the `⚠ Edit` sites) | Enumerated |
| Manual rebase procedure | [`rebase-runbook.md`](rebase-runbook.md) | Documented |

**Build and signing are on two different boxes by design** — the Leia signing box is **sign-only**
so long-running Chromium builds never clobber it. The pipeline must preserve that separation.

> **Trap: `build-browser.yml` (on `LeiaInc/codesign-runner`) is NOT the path to build on.** It targets
> a `[self-hosted, chromium-build]` runner (not our working AWS/`schtasks` path), has run exactly once
> and failed, **and signs in-place on the build box** — which would put the EV cert on the build box,
> violating sign-only-on-Leia. Either delete it or repoint it at the AWS box with the in-place signing
> stripped. Do not treat it as existing pipeline. (This doc's author was misled by it once.)

## Pipeline

```
         (cron 2×/day)                         ┌─ clean apply ─────────────┐
chromiumdash ──► new stable? ──► bump pin ──►  │  AWS box: build Official  │
  (Stable/Win)     │  no → exit                └──────────┬────────────────┘
                   │                                       │ build OK + DELAYLOAD OK
                   │                              ┌────────▼─────────┐
   emergency lane  │                              │   WEAVE GATE     │
 (manual dispatch, │                              │ diff touched vs  │
  0-day tag) ──────┘                              │ integration-pts  │
                                                  └───┬───────────┬──┘
                                    no weave files    │           │  weave files touched
                                      → auto-pass      │           │   → HOLD + Slack + eyeball
                                                       ▼           ▼
                              Leia box: sign (sign-artifact) ◄─ human approves
                                                       │
                                              release.sh → publish → bump update feed
                                                       │
                                          Slack notify (every terminal state)
```

### Phase 0 — Watcher *(new)*
A scheduled GitHub Action in **this repo** (cron ~2×/day) queries chromiumdash
(`fetch_releases?channel=Stable&platform=Windows&num=1`). If the reported stable version is newer
than `config.env CHROMIUM_TAG`, it opens/updates the pin and triggers Phase 1. A separate
`workflow_dispatch(tag)` **emergency lane** lets an on-call human force a rebase to a specific tag
immediately (actively-exploited 0-day), bypassing the poll.

### Phase 1 — Rebase + drift gate *(mostly exists)*
On the build box: `fetch`/`gclient sync` to the tag, then `git am --3way` the `patches/` series.
- **Clean apply** → continue to build.
- **Conflict** (`git am` fails) → **stop**, post to Slack, open a `rebase-drift` issue naming the
  tag + failing patch. A human resolves the drift on a branch (per `rebase-runbook.md`), updates the
  series, and re-triggers. This is the primary human gate and it is unavoidable — patch conflicts
  need judgment.

### Phase 2 — Build *(exists; needs headless lifecycle)*
`do_official18.ps1` semantics: `gn gen out/Official` → `autoninja chrome` (retry loop) → package →
DELAYLOAD check → tarball. **The gap:** the AWS box is **stop-by-default**, so the pipeline must
**start → build → stop** it without a human. `aws sso login` cannot refresh from a background job, so
this needs **non-interactive AWS credentials — a GitHub OIDC→AWS role** (preferred; no long-lived
secret) or a scoped IAM key. See [AWS lifecycle](#aws-box-lifecycle) below.

### Phase 3 — Weave gate *(new; the one real design call)*
Build-success + DELAYLOAD is enough for a Preview, not for "safe to use." We need cheap confidence
the weave didn't silently break across the rebase:

- Compute the set of **existing-Chromium files** the rebase changed (drift beyond a clean apply, i.e.
  any `git am` 3-way fuzz or a milestone that shifted the edit sites).
- Diff that set against the **`⚠ Edit` sites in `integration-points.md`** (the only rebase-fragile,
  weave-bearing files).
- **No intersection → auto-pass**: the weave code is byte-identical, so a green build cannot have
  broken it. Most security dot-releases land here → fully hands-off.
- **Intersection → HOLD**: Slack + require a human hardware eyeball (load a sample, confirm it weaves)
  before Phase 4. Only milestone rebases that ripple into the weave files hit this.

*Optional hardening (later):* a headless `sim_display` weave smoke on the box (launch a sample, grep
the service log for `batch weave n>0 eyes_valid`) to auto-gate even weave-file-touching rebases. The
file-diff heuristic gets ~90% of the value at ~zero cost, so it's the v1.

### Phase 4 — Sign *(reuse as-is)*
`scripts/sign.sh` → `sign-hook.sh` → `sign-artifact` on `sr_build_physical_box_2` (inner first-party
binaries), then the installer, then the outer `.exe` — exactly the 0.1.4 flow. **No change**, and it
keeps signing on the Leia box only.

### Phase 5 — Publish + notify *(thin glue)*
On gate-pass: `release.sh` publishes the signed installer to the release + **bumps the update feed**
(the pointer the browser's version check / future auto-updater reads). Slack-notify on **every**
terminal state — `published` / `drift-blocked` / `build-failed` / `sign-failed` / `gate-hold` — so
silence never hides a stalled *security* release.

## AWS box lifecycle

The one genuinely new piece of infra. To drive the stop-by-default build box headlessly:

- Add a **GitHub OIDC identity provider + IAM role** in the AWS account, trust-scoped to this repo's
  Actions, with a minimal policy: `ec2:StartInstances` / `ec2:StopInstances` /
  `ec2:DescribeInstances` on the build instance, plus SSM `SendCommand` to run the build (or SSH via
  a short-lived key). No long-lived secret on any box.
- Pipeline: assume the role → `StartInstances` → wait healthy → run the build (SSM/SSH) → pull the
  tarball → **`StopInstances` in a `finally` so a failed build never leaves the box (and the bill)
  running.**
- Cost: ~30 min/build × the box's hourly rate × ~2–4 builds/month ≈ a few dollars/month.

## Emergency 0-day lane

`workflow_dispatch(chromium_tag)` → same pipeline, expedited: if Phase 3 auto-passes (no weave files
touched — the common case for a security dot-release) it can publish without waiting on a human. The
on-call person only triggers it and watches Slack. Target: **patched build published within hours** of
a Chrome 0-day fix landing in stable.

## Explicitly out of scope here

- **Auto-update delivery** — required for the security commitment to reach users, tracked separately.
- **Widevine/DRM, Safe Browsing, Google Sync** — product-scope decisions, not part of the build
  cadence. (DRM confirmed absent today → non-DRM 1.0.)
- **macOS / Linux weave** — Windows/D3D11 only for 1.0.

## Open decisions

1. **AWS access model** — OIDC→AWS role (recommended) vs a scoped IAM key.
2. **Weave gate** — ship the file-diff heuristic first, or invest up front in the headless `sim`
   weave smoke?
3. **`build-browser.yml`** — delete, or repoint at the AWS box + strip in-place signing?
4. **Publish target on auto-pass** — fully auto-publish security dot-releases, or always land in a
   staged/pre-release state a human promotes? (Trades 0-day latency against a human backstop.)
