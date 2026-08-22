# The credential-free build lane (GitHub OIDC + SSM)

How CI drives the Chromium build box with **no stored AWS secret and no local credentials** — and
how to build a twin of it for the Linux/Android arm (browser#100).

Everything below is read out of the shipping Windows lane
([`.github/workflows/build-box.yml`](../.github/workflows/build-box.yml),
[`scripts/aws/`](../scripts/aws/)) and out of the **live IAM role**, not from memory. Where a value
is account-specific it is marked as something the porter supplies.

---

## What the lane gives you

A `workflow_dispatch`/`workflow_call` job on a stock `ubuntu-latest` runner that: mints a short-lived
GitHub OIDC token, trades it for a least-privilege AWS role, starts a stopped EC2 build box, waits
for its SSM agent, pushes a driver script to it over **SSM RunCommand** (no SSH, no open port, no
key), polls a marker file until the multi-hour build finishes, pulls the artifact back through S3,
and **always** stops the box again. There is no `AWS_ACCESS_KEY_ID` in the repo secrets, nothing in
`.secrets/`, nothing on anyone's laptop; the only stored config is a *public* repo **variable**
holding the role ARN. Anyone with `workflow_dispatch` rights on the repo can run a build from any
box — or from the GitHub web UI — and the run is fully auditable in CloudTrail under a
per-run `role-session-name`.

---

## The four moving parts

| Part | Where | Job |
|---|---|---|
| **OIDC trust** | IAM: an OIDC provider for `token.actions.githubusercontent.com` + a role whose trust policy pins the token's `sub` | Replaces the stored secret. Only *this repo*, only jobs declaring `environment: build-box`, can assume the role. |
| **Least-privilege policy** | Inline policy `BuildBoxAndArtifacts` on that role | Start/stop **one** instance, `ssm:SendCommand` to **one** instance + **one** document, read/write **one** bucket, explicit `Deny` on terminate. |
| **The transport** | [`scripts/aws/ssm-run.sh`](../scripts/aws/ssm-run.sh) → SSM RunCommand | Sends lines of script to the box, waits, surfaces stdout/stderr, turns SSM status into an exit code. Re-mints credentials mid-wait. |
| **The remote driver** | [`remote-build.ps1`](../scripts/aws/remote-build.ps1) / [`remote-rebase.ps1`](../scripts/aws/remote-rebase.ps1) → [`do_rebase.ps1`](../scripts/aws/do_rebase.ps1) | Runs *on* the box. Triggers the real work under the right user, polls a `.done` marker, translates the verdict into an explicit exit code. |

Two things deliberately do **not** travel over SSM:

- **The patch series is pulled, not pushed.** `do_rebase.ps1` step 0 downloads
  `https://codeload.github.com/DisplayXR/displayxr-browser/zip/<ref>` and unpacks `patches/`. The
  series is ~3.5 MB, far past the RunCommand payload limit, and the repo is public so this needs no
  extra AWS permission and no credential on the box. It uses `Invoke-WebRequest`, **not git** —
  under a scheduled task there is no console, so a git credential-helper or host-key prompt blocks
  forever and is indistinguishable from slow work (that cost three runs).
- **The artifact is pushed to S3 by the box** with its *own* instance-profile credentials, and the
  runner downloads it. The runner never streams hundreds of MB through SSM.

The scripts themselves *are* staged over SSM — but as **base64**, not as files:

```bash
b64=$(base64 -w0 scripts/aws/remote-build.ps1)
printf '%s\n' \
  "[IO.File]::WriteAllBytes(\"C:\\build\\remote-build.ps1\", [Convert]::FromBase64String(\"${b64}\"))" \
  "& powershell -NoProfile -ExecutionPolicy Bypass -File C:\\build\\remote-build.ps1 -Job '${JOB}'" \
  'exit $LASTEXITCODE' \
| scripts/aws/ssm-run.sh "$INSTANCE_ID" "CI build ${GITHUB_RUN_ID}" "$TIMEOUT_MIN"
```

Base64 because a script body sent as literal command lines has to survive YAML → bash → JSON →
PowerShell quoting intact, and it does not: backslashes and embedded quotes get eaten. One base64
blob has no metacharacters at all. (Note `printf '%s\n'` with the payload as **arguments**, never in
printf's *format* string — a format string eats `\b` and turns `C:\build` into `C:uild`.)

---

## The IAM trust policy (live values)

Read back from the account with `aws iam get-role --role-name DisplayXRBrowserBuildBox`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::172723492117:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:DisplayXR/displayxr-browser:environment:build-box"
      }
    }
  }]
}
```

- Role ARN: `arn:aws:iam::172723492117:role/DisplayXRBrowserBuildBox` (repo variable
  `AWS_BUILD_ROLE_ARN`)
- `MaxSessionDuration`: **7200 s** — which is why the workflow asks for `role-duration-seconds: 7200`
  rather than the action's 3600 default.
- Attached managed policies: **none**. One inline policy, `BuildBoxAndArtifacts`.

### Why the `sub` condition is the whole security story

`sub` is the *subject* claim GitHub stamps into the OIDC token it mints for a job. GitHub — not the
workflow author — decides its value, and it encodes exactly which repository and which context the
job is running in. `StringEquals` on it means STS will hand out credentials **only** to a token
carrying that literal string. So:

- Another repo in the org cannot assume the role — its `sub` starts `repo:DisplayXR/<other>:`.
- A fork's PR build cannot assume it — a fork's `sub` names the fork.
- A branch in *this* repo cannot assume it unless the job declares `environment: build-box`, because
  the environment form of `sub` is `repo:<org>/<repo>:environment:<env>`.

That last point makes `environment: build-box` on the job **load-bearing, not decorative** — drop
the line and `AssumeRole` fails. It also gives you a place to hang required reviewers later: an
environment protection rule gates the credential itself, not just the deploy.

**The failure mode of an over-broad `sub`.** A wildcard like `repo:DisplayXR/*:*` — or the seductive
`repo:DisplayXR/displayxr-browser:*` — means *any workflow, on any branch, in scope* can assume the
role. Since anyone who can open a PR can propose a workflow file, and workflows on a branch run with
that branch's contents, a wildcard `sub` converts "can push a branch" into "can start, drive and
stop our EC2 fleet". Scope to a specific ref (`:ref:refs/heads/main`) or, better, an environment.
There is no secret to leak here; the trust condition **is** the credential.

### The permissions the role actually needs

Live inline policy `BuildBoxAndArtifacts`, verbatim from `aws iam get-role-policy`:

| Sid | Actions | Resource |
|---|---|---|
| `Describe` | `ec2:DescribeInstances`, `ec2:DescribeInstanceStatus`, `ec2:DescribeTags` | `*` — EC2 cannot resource-scope `Describe*`; read-only, harmless |
| `StartStopBuildBoxOnly` | `ec2:StartInstances`, `ec2:StopInstances` | `arn:aws:ec2:us-east-1:172723492117:instance/i-0150c4a09e3852120` |
| `RunTheBuildViaSSM` | `ssm:SendCommand` | the same instance ARN **and** `arn:aws:ssm:us-east-1::document/AWS-RunPowerShellScript` |
| `PollSSMResults` | `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations`, `ssm:ListCommands`, `ssm:DescribeInstanceInformation` | `*` |
| `Artifacts` | `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` | `arn:aws:s3:::displayxr-browser-artifacts` + `/*` |
| `NeverTerminate` | **Deny** `ec2:TerminateInstances`, `ec2:RunInstances` | `*` |

`ssm:SendCommand` needs **both** the instance ARN and the *document* ARN — granting only one of them
fails with an unhelpful `AccessDeniedException`. Pinning the document is what stops the role being a
general remote-shell over the account.

`NeverTerminate` is not paranoia: the box carries a multi-hour Chromium checkout that a terminate
would destroy. An explicit `Deny` outranks any future `Allow`.

**The box's own credentials are separate.** The instance runs with instance profile
`AmazonSSMRoleForInstancesQuickSetup` — the account-standard SSM profile shared by 20+ instances —
so `s3:PutObject` is granted **resource-side** by a bucket policy instead of by adding it to that
shared role (verified live):

```json
{"Sid":"BuildBoxInstanceMayUploadBuildsOnly","Effect":"Allow",
 "Principal":{"AWS":"arn:aws:iam::172723492117:role/AmazonSSMRoleForInstancesQuickSetup"},
 "Action":"s3:PutObject","Resource":"arn:aws:s3:::displayxr-browser-artifacts/builds/*",
 "Condition":{"StringEquals":{"ec2:SourceInstanceARN":
   "arn:aws:ec2:us-east-1:172723492117:instance/i-0150c4a09e3852120"}}}
```

The `ec2:SourceInstanceARN` condition is what keeps the other 20 instances out.

One-time setup is scripted and idempotent: [`scripts/aws/setup-oidc.sh`](../scripts/aws/setup-oidc.sh)
(dry-run by default; `--apply` to make it so). It creates the OIDC provider, the role, the inline
policy, the bucket + block-public-access, the bucket policy, associates the SSM instance profile, and
prints the role ARN to paste into the repo variable.

---

## The workflow skeleton (liftable)

```yaml
permissions:
  contents: read
  id-token: write            # REQUIRED — without it there is no OIDC token to trade

concurrency:                 # one build at a time; the box is a single shared instance
  group: build-box
  cancel-in-progress: false  # cancelling would fire the always() stop under a live build

env:
  AWS_REGION: us-east-1
  INSTANCE_ID: i-0150c4a09e3852120
  ARTIFACT_BUCKET: displayxr-browser-artifacts
  AWS_BUILD_ROLE_ARN: ${{ vars.AWS_BUILD_ROLE_ARN }}   # ssm-run.sh re-mints with this

jobs:
  build:
    runs-on: ubuntu-latest
    environment: build-box   # load-bearing: it is what makes the token's `sub` match
    steps:
      - uses: actions/checkout@v4

      - name: Assume AWS role (OIDC, no stored secret)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_BUILD_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: gha-build-box-${{ github.run_id }}   # CloudTrail identity
          role-duration-seconds: 7200                              # role's MaxSessionDuration

      - name: Start the build box
        run: |
          state=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
                  --query 'Reservations[0].Instances[0].State.Name' --output text)
          [ "$state" = running ] || aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
          aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

      - name: Wait for SSM agent
        run: |
          # The agent registers a little AFTER the instance reports running. A stopped
          # instance is absent from describe-instance-information entirely.
          for i in $(seq 1 40); do
            ping=$(aws ssm describe-instance-information \
                    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
                    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
            [ "$ping" = Online ] && exit 0
            sleep 15
          done
          echo "::error::SSM agent never came Online"; exit 1

      # ... stage driver as base64 + ssm-run.sh (see above) ...

      - name: Re-assume AWS role before the artifact upload
        uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: "${{ vars.AWS_BUILD_ROLE_ARN }}", aws-region: us-east-1,
                role-session-name: gha-upload-${{ github.run_id }}, role-duration-seconds: 7200 }

      - uses: actions/upload-artifact@v4
        with: { name: browser-build, path: dist/, retention-days: 7 }

      - name: Re-assume AWS role for cleanup
        if: always()
        uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: "${{ vars.AWS_BUILD_ROLE_ARN }}", aws-region: us-east-1,
                role-session-name: gha-stop-${{ github.run_id }}, role-duration-seconds: 7200 }

      - name: Stop the build box
        if: always()
        run: |
          aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
          aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" || true
          state=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
                    --query 'Reservations[0].Instances[0].State.Name' --output text)
          case "$state" in stopped|stopping) ;;
            *) echo "::error::box is '$state', NOT stopped — it is still billing."; exit 1 ;; esac
```

### Why the role is re-assumed three times

**The build outlives the credentials.** The session is capped by the role's `MaxSessionDuration`
(2 h here), while the build step alone is allowed 180 minutes. So on any long build the credentials
minted at the top of the job are already dead by the time the build returns.

`if: always()` does **not** save you: the step runs, the API call is refused with `RequestExpired`,
and the instance is left **running and billing** — that happened for real and was cleaned up by hand.
Likewise the artifact upload: run 30933222808 rebased and built successfully in 2 h 04 m, then lost
the tarball to `ExpiredTokenException ... calling the SendCommand operation`. Two hours of build
thrown away, and the run reported `failure` for a credential lifetime rather than anything about the
code.

Re-assume rather than raise the duration: the duration is capped by IAM, so raising it needs an IAM
change *and* still fails for any run that outlives the new cap. **A fresh assume immediately before
each credential-using step is correct for a run of any length.** GitHub's OIDC token endpoint stays
available for the whole job, so this mints a genuinely new token, not a cached one.

The same reasoning drives `refresh_aws_creds()` inside `ssm-run.sh`, which re-mints *mid-wait* when
the poll loop starts failing: `sts assume-role-with-web-identity` is an **unsigned** call, so it
works even when the credentials you currently hold have already expired. That is what makes the
situation recoverable instead of chicken-and-egg. And never conflate "cannot query" with "not
started" — an earlier version reported every API failure as the literal status `Pending`, producing
a run that appeared to sit in Pending for 70 minutes and a verdict blaming the SSM agent, when the
truth was that we had merely stopped being able to *read* the status.

---

## The remote driver + marker pattern

RunCommand gives you a synchronous "run these lines, tell me the status". Real builds are
asynchronous and privileged, so a thin driver bridges the two:

1. **Privilege.** RunCommand executes as `NT AUTHORITY\SYSTEM`, but depot_tools must run as
   Administrator. So the driver *triggers a pre-registered scheduled task* (`crbuild`, registered
   Run-As Administrator) rather than invoking the build script directly. On Linux the equivalent
   is `sudo -u <builduser>` or a systemd unit — same idea, different mechanism.

2. **`schtasks /Run` returns on launch, not on completion.** A naive trigger reports success
   instantly with no build. Hence markers.

3. **The marker contract** (written by the build script, polled by the driver):

   | File | Meaning |
   |---|---|
   | `C:\build\<job>.done` | Written **last**: `DONE` on success, `ERROR: <msg>` on failure |
   | `C:\build\<job>.status` | Progress lines appended as the build moves through stages |
   | `C:\build\<job>.log` | Full build log |

   The driver **deletes `.done` up front**, so a stale marker from a previous run can never be read
   as this run's verdict. It then confirms the task actually entered `Running` (a disabled or
   mis-registered task otherwise looks identical to an instant success), polls `.done` on a 30 s
   loop against a deadline, and prints a heartbeat every ~5 min so a 90-minute invocation is
   visibly alive.

   Heartbeat detail worth stealing: `remote-rebase.ps1` prints the **last `=== stage ===` marker plus
   the log size**, not the last raw line. `gclient` writes progress as one `\r`-updated blob, so
   "the last line" is a megabyte of spinner that never changes. That ambiguity cost three runs'
   worth of misdiagnosis.

4. **Explicit exit codes.** `0` OK / `1` the work reported ERROR / `2` task never started / `3`
   timed out. These are explicit because **SSM reports `Status=Success` for a script that merely
   *prints* an error** — verified on this box, where two command-not-found errors came back as a
   green invocation. `ssm-run.sh` then exits non-zero unless SSM says `Success`, and the job fails.

5. **Log encoding is part of the contract.** `Tee-Object` on PowerShell 5.1 writes UTF-16LE with a
   BOM while `cmd /c ... >> log` appends ANSI; the mixture made `Get-Content` return mojibake and
   the progress line stopped advancing regardless of real progress. Write one encoding
   (`Add-Content -Encoding ascii`). The Linux twin's analogue is simply: don't mix a
   `tee` that adds colour codes with raw redirects.

---

## Porting checklist — a Linux + Android twin

Everything above ports. What changes:

- [ ] **A second role, not a shared one.** Create `DisplayXRBrowserAndroidBuildBox` with the *same*
      trust shape but its own `sub` — e.g.
      `repo:DisplayXR/displayxr-browser:environment:build-box-android` — and its own instance ARN in
      the permissions policy. A second GitHub environment (`build-box-android`) keeps the two lanes
      from being able to drive each other's box. `setup-oidc.sh` is already parameterised for this:
      `ROLE_NAME`, `GH_ENV`, `INSTANCE_ID`, `ARTIFACT_BUCKET` are all env overrides — run it with
      those set, `--apply`, and paste the printed ARN into a second repo variable
      (`AWS_ANDROID_BUILD_ROLE_ARN`).
- [ ] **The OIDC provider is already there.** `token.actions.githubusercontent.com` exists in the
      account (verified). Do not create a second one — IAM allows only one per URL.
- [ ] **`--document-name AWS-RunShellScript`**, not `AWS-RunPowerShellScript` — in `ssm-run.sh`'s
      `send-command` *and* in the role policy's `RunTheBuildViaSSM` Sid
      (`arn:aws:ssm:<region>::document/AWS-RunShellScript`). Getting the document ARN wrong is an
      `AccessDeniedException`, not a "no such document".
- [ ] **The instance needs an SSM instance profile and a running SSM agent.** The Windows box shipped
      with `IamInstanceProfile=None` and RunCommand was simply impossible (empty
      `describe-instance-information`, `PingStatus` none). Attach the account-standard profile
      (`AmazonSSMRoleForInstancesQuickSetup`) — SWE-DEV can associate an existing profile but cannot
      mint a new one. On Amazon Linux/Ubuntu confirm `amazon-ssm-agent` is installed and enabled;
      Ubuntu AMIs often ship it as a snap that needs enabling.
- [ ] **Drop the base64/`WriteAllBytes` staging for `base64 -d`**, and stage to `/opt/build/` or
      `~builder/` rather than `C:\build\`. The base64 wrapper is still worth keeping — it is what
      makes the payload metacharacter-free.
- [ ] **Privilege escalation mechanism.** No `schtasks`. Use `sudo -u builder` (RunCommand's Linux
      agent runs as root, so you are stepping *down*, which is easier than the Windows case), or a
      `systemd-run --unit=crbuild` one-shot polled the same way. Keep the marker protocol identical:
      `<job>.done` written last, deleted up front, `.status`/`.log` alongside.
- [ ] **Patch pull, not push, is unchanged** — codeload zip over HTTPS, `unzip`, copy `patches/*.patch`.
      Same reasoning (payload limit, public repo, no credential, no interactive prompt).
- [ ] **Artifact:** the box `aws s3 cp`s the APK to `builds/${GITHUB_RUN_ID}/...` under its own
      instance-profile credentials; the bucket policy needs a second statement (or a second bucket)
      with `ec2:SourceInstanceARN` pinned to the **Linux** instance. Then the same
      re-assume → `aws s3 cp` down → `upload-artifact` tail. An APK is small enough that you could
      base64 it back through RunCommand — **don't**; the RunCommand output cap will truncate it.
- [ ] **Make it `workflow_dispatch` with a `lifecycle_only: true` default**, exactly as the Windows
      lane does. That default is what lets anyone smoke-test the OIDC + start/stop path in ~2 minutes
      without spending a build, and it makes recapture round-trips verifiable from either box.
      Expose `patch_ref` so a run can be pinned to an exact commit of this repo.
- [ ] **Add a `concurrency:` group** — a *different* group from `build-box`, since it is a different
      instance, but with `cancel-in-progress: false` for the same reason: a cancelled run's
      `always()` stop step would stop the box under the other run's live build.
- [ ] **Keep the `if: always()` stop guard and its state assertion.** A green run with a quiet error
      line is how you discover a month later that the box never stopped.
- [ ] **Nothing in `.env.local` or `.secrets/` should remain load-bearing** once this lands — that is
      the point of the port. Keep the SSH key only as a break-glass path for interactive debugging;
      CI must not need it.

---

## Traps

### 1. The SSM parameter parser splits on commas

`--parameters 'commands=[...]'` is parsed with comma as the element separator, so **any comma inside
your one-liner becomes a new command line**. A PowerShell fragment like `[Math]::Max(0, $i - 45)` is
silently torn into `[Math]::Max(0` and ` $i - 45)`, and each half is executed as its own command.
The failure is not a parse error — it is two commands that do something else.

Two fixes, in order of preference:

- **Use a JSON parameter file.** This is what `ssm-run.sh` does, building it with `jq` and passing
  `--parameters "file://$params"`. Commas, backslashes and quotes are then just JSON string content.
  Do not "simplify" it back to an inline `commands=[...]`.
- **Write comma-free** when you genuinely need a one-liner:
  `$s = $i - 45; if ($s -lt 0) { $s = 0 }` instead of `[Math]::Max(0, $i - 45)`.

**Companion trap:** `scripts/aws/ssm-run.sh` **fails when invoked from Git Bash on Windows**. It
writes its paramfile with `mktemp` to a Git-Bash `/tmp/...` path, and the Windows-native `aws.exe`
resolves `file:///tmp/...` as `C:\tmp\...`, which does not exist. (`setup-oidc.sh` already works
around this with a `cygpath -w` helper; `ssm-run.sh` does not.) From a Git Bash prompt on Windows,
call `aws ssm send-command` directly from **PowerShell** instead, or convert the path yourself. On
the `ubuntu-latest` runner — the only place CI ever runs it — the script is fine.

### 2. Measure your driver's length limits

browser#132: `do_rebase.ps1` inlined every patch path into a single `cmd /c` string, ~82 chars per
patch. At 99 patches the string crossed cmd.exe's ceiling (~8156 chars for the string handed to
`cmd`), cmd rejected **the whole command**, and because the `>> $LOG 2>&1` redirect was part of the
same rejected string, `rebase.log` received not one byte. `$LASTEXITCODE` was 1, so the drift gate
reported *"patch series did not apply cleanly"* — for a series that applies perfectly. A full
diagnosis cycle went into the wrong repo.

Two rules come out of it:

1. **A "tool failed" verdict must first establish that the tool STARTED.** Zero `Applying:` lines in
   the log was the tell; so was `git am --abort` answering *"Resolve operation not in progress"*.
   `do_rebase.ps1` now branches on exactly that and says
   *"git am NEVER STARTED — HARNESS fault, not a patch conflict. The series was NOT tested and is
   not implicated."* Any gate that can blame its input for its own overflow needs this branch.
2. **Any command string whose length grows with the input needs a length tripwire.** The fix
   ([PR #133](https://github.com/DisplayXR/displayxr-browser/pull/133)) was not a bigger budget — it
   was a **constant-length** command line: concatenate the whole series into one `series.mbox` (which
   is exactly what `git format-patch` output already is) and pass **one** path. Plus a guard:

   ```powershell
   $CMD_MAX = 8000                 # cmd.exe ceiling ~8156; leave slack
   function RunCmd($c){
     if ($c.Length -gt $CMD_MAX) { Fail ("internal: cmd line is " + $c.Length + " chars ...") }
     cmd /c $c
   }
   ```

   The Linux twin has a much larger `ARG_MAX`, so it will not hit this at 100 patches — but it will
   hit it eventually, and `xargs`-style splitting reintroduces the "which invocation failed?"
   ambiguity. Concatenate to one mbox there too, and keep the tripwire.

   The mbox copy must be **byte-level** (`[IO.File]::ReadAllBytes` / `cat` — not
   `Get-Content`/`Set-Content`), because PS 5.1's encoding and line-ending round-trip corrupts the
   base85 payload of the binary hunks and every patch's context whitespace with it.

---

## Verified vs. supply-your-own

**Verified from source and from the live account (2026-08-22):** the trust policy and its `sub`
condition, `MaxSessionDuration=7200`, the inline `BuildBoxAndArtifacts` policy (no managed policies
attached), the artifact bucket policy and its `ec2:SourceInstanceARN` condition, the instance profile
`AmazonSSMRoleForInstancesQuickSetup`, and the existence of the account's
`token.actions.githubusercontent.com` OIDC provider. All read with `iam get-role`,
`iam get-role-policy`, `s3api get-bucket-policy`, `ec2 describe-instances`.

**A porter supplies for their own lane:** the Linux instance ID and its ARN, a second role name and
GitHub environment, the artifact bucket (or prefix) and its instance-scoped bucket policy statement,
and confirmation that the Linux box's SSM agent registers (`PingStatus=Online`) once it is started —
which cannot be checked while the box is stopped, because SSM drops stopped instances out of
`describe-instance-information` entirely.
