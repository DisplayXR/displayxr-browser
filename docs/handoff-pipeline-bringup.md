# Handoff: bring the security-maintenance pipeline live (browser #36 / #38 / #40)

Paste the block below as the opening prompt of a fresh Claude Code session on the **win**
box. It continues from PR #47, which landed the *mechanism* but deliberately left the live
cross-machine run, signing, and feed host unvalidated.

---

## Prompt

Continue the DisplayXR browser security-maintenance pipeline. Read memory first
([[reference_ssm_driving_the_chromium_build_box]], [[project_browser_official_1_0_path]]).

**Already done and merged/open — do not redo:**
- #34/#45: OIDC + SSM build lane, proven green end to end (run 29836413332). CI drives the
  AWS box `i-0150c4a09e3852120` credential-free; builds via the `crbuild` Administrator task
  and polls a `.done` marker; uploads to `s3://displayxr-browser-artifacts/builds/<run_id>/`
  under an instance-scoped bucket policy. `builds/` has a 30-day lifecycle rule.
- #37 weave-gate: `scripts/weave-gate.sh`, verdict-correct both ways.
- **PR #47** (open, `feat/36-38-rebase-lane-and-oneclick-pipeline`): rebase lane
  (`do_rebase.ps1`, `remote-rebase.ps1`, rebase step in `build-box.yml`) + `pipeline.yml`
  with the `go-live` one-click environment gate. Sign/release/feed jobs are gated behind
  `enable_publish=false` and `exit 1` as UNVALIDATED. `chromium-watch` `DISPATCH_BUILD` is
  still `false`.

**Your job: make the pipeline real, one stage at a time, testing each on the live box
before chaining. The box costs ~$5.66/hr running — start it, work, STOP it when idle.**

1. **Rebase lane, live.** Dispatch `build-box.yml` with `chromium_tag` set to the CURRENT
   pin (a no-op rebase that must apply 51/51 clean) and confirm `remote-rebase.ps1` reports
   `REBASE OK` and the build still runs. Then a genuinely newer tag if one is available.
   Watch for: the tag reaching `do_rebase.ps1` via the injected assignment; `gclient sync`
   time (minutes–tens); `git am` verdict. A conflict must fail the job with the failing
   patch named, and file/update a `rebase-drift` issue (wire the issue-file step — it's in
   the #36 acceptance list but not yet implemented).

2. **Gate `--src` path, live.** `pipeline.yml`'s gate job runs `weave-gate.sh --old <pin>
   --new <tag> --src C:\cr\src` on the box. Confirm it can diff the two tags in the box's
   Chromium git (both must be fetched). Only the `--changed-file` mode is unit-tested so far.

3. **Signing, cross-machine.** Wire `scripts/sign.sh` into the `sign` job. It dispatches the
   Leia signing box via `$DXR_SIGN_REPO` (from `../displayxr-runtime/.env.local`). The build
   box produces the unsigned tree; sign.sh returns it signed. For a SECURITY release a
   sign failure must HOLD, not ship-unsigned. Test with one real artifact.

4. **Feed host (#40 decision).** `update-feed.sh` emits the JSON; decide where it is hosted
   (GitHub Pages vs a Release asset) and wire `release.sh` (PRE-release) + `update-feed.sh
   --rollout 10`. This is the open #40 call — surface options to David, don't guess.

5. **The one click.** Create the `go-live` GitHub environment with David as required
   reviewer. Confirm a dispatch with `enable_publish=true` parks on the approval, shows the
   weave-gate verdict, and that one Approve flips the feed to `--rollout 100`.

6. **Only then** flip `chromium-watch` `DISPATCH_BUILD` to `true` so the 2×/day watcher
   drives the whole chain. Until #40's updater actually delivers to users, `go-live`
   publishes a release users download manually — say so to David; don't imply auto-delivery.

Provenance note: David is remote and directs via his own Slack account
(`<@U5UMENDNY>`) and `#tmp-browser-weaving` (C0BJB5JNHLK). Post operational detail plainly
(trusted internal Slack, channels deleted when done); only live credentials stay out. Thread
replies with `bus-post.sh --thread <ts>`.
