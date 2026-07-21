#!/usr/bin/env bash
# setup-oidc.sh — one-time AWS setup so GitHub Actions can drive the Chromium build box
# with NO long-lived secret (browser#34, decision #1 on browser#33).
#
# Creates/updates, idempotently:
#   1. the GitHub OIDC identity provider (token.actions.githubusercontent.com)
#   2. an IAM role the workflow assumes via OIDC, trust-scoped to this repo + a GitHub
#      *environment* (so the sub is `repo:<org>/<repo>:environment:<env>`)
#   3. a least-privilege policy: start/stop the ONE build instance, SSM RunCommand on it,
#      and read the build artifact from S3
#   4. (checks) the instance can be driven by SSM and can write the artifact bucket
#
# Nothing here is destructive: every step is create-or-update. Re-running is safe.
#
# Usage:
#   aws sso login --profile displayxr        # interactive, do this first
#   scripts/aws/setup-oidc.sh [--apply]      # default is a DRY RUN that only reports
#
# Env (defaults match displayxr-runtime/.env.local):
#   AWS_PROFILE   default displayxr
#   AWS_REGION    default us-east-1
#   INSTANCE_ID   the Chromium build box
#   GH_ORG/GH_REPO/GH_ENV   trust scoping
#   ROLE_NAME / ARTIFACT_BUCKET
set -uo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

AWS_PROFILE="${AWS_PROFILE:-displayxr}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_ID="${INSTANCE_ID:-i-0150c4a09e3852120}"
GH_ORG="${GH_ORG:-DisplayXR}"
GH_REPO="${GH_REPO:-displayxr-browser}"
GH_ENV="${GH_ENV:-build-box}"
ROLE_NAME="${ROLE_NAME:-DisplayXRBrowserBuildBox}"
POLICY_NAME="${POLICY_NAME:-BuildBoxAndArtifacts}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-displayxr-browser-artifacts}"
# The account-standard SSM instance profile (20+ instances use it). SWE-DEV can attach an
# EXISTING profile (ec2:AssociateIamInstanceProfile is allowed) but cannot mint a new one
# (iam:CreateInstanceProfile / AddRoleToInstanceProfile are DENIED), so we reuse this one
# rather than creating a dedicated build-box profile.
SSM_INSTANCE_PROFILE="${SSM_INSTANCE_PROFILE:-AmazonSSMRoleForInstancesQuickSetup}"

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
say() { echo "[setup-oidc] $*"; }
# A Windows-native aws.exe cannot read an MSYS/Cygwin "/tmp/..." path out of a file://
# reference (it reads it as C:\tmp\...). Emit a native path when we're on such a shell.
pathref() {
  if command -v cygpath >/dev/null 2>&1; then printf 'file://%s' "$(cygpath -w "$1")"
  else printf 'file://%s' "$1"; fi
}
run() {
  if [ "$APPLY" = "1" ]; then "$@"; else say "DRY RUN would: $*"; fi
}

# ── preflight ────────────────────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "[setup-oidc] ERROR: no valid AWS session. Run: aws sso login --profile $AWS_PROFILE" >&2
  exit 1
}
say "account=$ACCOUNT region=$AWS_REGION instance=$INSTANCE_ID apply=$APPLY"

OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
INSTANCE_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT}:instance/${INSTANCE_ID}"

# ── 1. OIDC provider ─────────────────────────────────────────────────────────────────
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  say "OIDC provider already present"
else
  say "OIDC provider MISSING -> create"
  # Thumbprint is ignored for this provider by IAM today (it validates via a trusted CA),
  # but the API still requires one; this is the long-published GitHub value.
  run aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
fi

# ── 2. role + trust policy ───────────────────────────────────────────────────────────
# sub is scoped to the GitHub *environment*, the tightest practical scope: only a job that
# declares `environment: <GH_ENV>` can assume this role — which also gives us a place to
# hang required reviewers later (the human-promote gate in browser#38).
TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${GH_ORG}/${GH_REPO}:environment:${GH_ENV}"
      }
    }
  }]
}
JSON
)
TRUST_FILE="$(mktemp)"; printf '%s' "$TRUST" > "$TRUST_FILE"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # NOTE: AWSReservedSSO_SWE-DEV is DENIED iam:UpdateAssumeRolePolicy — CreateRole,
  # PutRolePolicy, DeleteRole and DeleteRolePolicy are allowed, but changing an existing
  # trust policy is not. To re-scope trust under SWE-DEV you must delete and recreate the
  # role (DeleteRolePolicy on every inline policy first, then DeleteRole, then re-run).
  say "role $ROLE_NAME exists -> update trust policy (expect AccessDenied under SWE-DEV)"
  run aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$(pathref "$TRUST_FILE")"
else
  say "role $ROLE_NAME MISSING -> create"
  run aws iam create-role --role-name "$ROLE_NAME" \
    --description "GitHub Actions (browser#34): drive the Chromium build box, no long-lived secret" \
    --assume-role-policy-document "$(pathref "$TRUST_FILE")"
fi

# ── 3. least-privilege permissions ───────────────────────────────────────────────────
# Describe* cannot be resource-scoped by EC2, so it is "*" (read-only, harmless).
# Start/Stop are pinned to the ONE build instance. SSM is pinned to that instance plus the
# RunPowerShellScript document. S3 read is pinned to the artifact prefix.
PERMS=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Describe",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeTags"],
      "Resource": "*"
    },
    {
      "Sid": "StartStopBuildBoxOnly",
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances"],
      "Resource": "${INSTANCE_ARN}"
    },
    {
      "Sid": "RunTheBuildViaSSM",
      "Effect": "Allow",
      "Action": ["ssm:SendCommand"],
      "Resource": [
        "${INSTANCE_ARN}",
        "arn:aws:ssm:${AWS_REGION}::document/AWS-RunPowerShellScript"
      ]
    },
    {
      "Sid": "PollSSMResults",
      "Effect": "Allow",
      "Action": [
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations",
        "ssm:ListCommands",
        "ssm:DescribeInstanceInformation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Artifacts",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${ARTIFACT_BUCKET}",
        "arn:aws:s3:::${ARTIFACT_BUCKET}/*"
      ]
    },
    {
      "Sid": "NeverTerminate",
      "Effect": "Deny",
      "Action": ["ec2:TerminateInstances", "ec2:RunInstances"],
      "Resource": "*"
    }
  ]
}
JSON
)
PERMS_FILE="$(mktemp)"; printf '%s' "$PERMS" > "$PERMS_FILE"
say "attach inline policy $POLICY_NAME to $ROLE_NAME"
run aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" --policy-document "$(pathref "$PERMS_FILE")"

# ── 4. instance side: the SSM instance profile ───────────────────────────────────────
# The build box shipped with IamInstanceProfile=None, so the SSM Agent had no credentials
# to register with and RunCommand was impossible (PingStatus none, empty
# describe-instance-information). Attaching the account-standard profile fixes it; the
# agent registers within ~20s of the instance reaching `running`.
say "--- instance profile ---"
CUR_PROFILE="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text 2>/dev/null)"
if [ "${CUR_PROFILE:-None}" = "None" ] || [ -z "${CUR_PROFILE:-}" ]; then
  say "instance has NO profile -> associate $SSM_INSTANCE_PROFILE"
  run aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=$SSM_INSTANCE_PROFILE"
else
  say "instance profile already attached: $CUR_PROFILE"
fi

# ── 5. artifact bucket + instance-scoped write ───────────────────────────────────────
# The build box uploads the tarball itself, using its instance-profile credentials. Those
# come from the SHARED SSM role, so we grant the write resource-side with a bucket policy
# conditioned on ec2:SourceInstanceARN instead of attaching s3:PutObject to that role -
# otherwise every instance sharing the profile could write here. Confined to builds/*.
say "--- artifact bucket ---"
if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
  say "bucket $ARTIFACT_BUCKET exists"
else
  say "bucket $ARTIFACT_BUCKET MISSING -> create + block public access"
  run aws s3api create-bucket --bucket "$ARTIFACT_BUCKET"
  run aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
BUCKET_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "BuildBoxInstanceMayUploadBuildsOnly",
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT}:role/${SSM_INSTANCE_PROFILE}" },
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::${ARTIFACT_BUCKET}/builds/*",
    "Condition": {
      "StringEquals": { "ec2:SourceInstanceARN": "${INSTANCE_ARN}" }
    }
  }]
}
JSON
)
BUCKET_POLICY_FILE="$(mktemp)"; printf '%s' "$BUCKET_POLICY" > "$BUCKET_POLICY_FILE"
say "apply instance-scoped bucket policy"
run aws s3api put-bucket-policy --bucket "$ARTIFACT_BUCKET" \
  --policy "$(pathref "$BUCKET_POLICY_FILE")"

# ── 6. prerequisite checks (report only) ─────────────────────────────────────────────
say "--- prerequisite checks ---"
SSM_OK="$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"
if [ "$SSM_OK" = "Online" ]; then
  say "SSM: instance is Online (RunCommand will work)"
else
  say "SSM: not Online (PingStatus=${SSM_OK:-none}) — expected while the box is stopped;"
  say "     SSM drops stopped EC2 instances out of describe-instance-information entirely."
fi
if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
  say "S3: artifact bucket $ARTIFACT_BUCKET reachable"
  # The box uploads with its OWN instance-profile credentials. Those come from the shared
  # SSM role, so the write is granted resource-side by a BUCKET POLICY conditioned on
  # ec2:SourceInstanceARN, not by adding s3:PutObject to that role - which would have let
  # all 20+ instances sharing it write here. Verified: builds/* from this instance
  # succeeds, anything outside builds/* is denied.
  if aws s3api get-bucket-policy --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
    say "S3: bucket policy present (instance-scoped PutObject under builds/*)"
  else
    say "S3: NO bucket policy - the box cannot upload. See browser#45."
  fi
  say "NOTE: SWE-DEV is denied s3:PutLifecycleConfiguration, so builds/ does NOT expire"
  say "      automatically. Each build is ~380 MB; prune it or ask DevOps for a rule."
else
  say "S3: bucket $ARTIFACT_BUCKET does not exist - the artifact hand-off cannot work."
fi

echo
say "ROLE ARN (set as repo variable AWS_BUILD_ROLE_ARN): $ROLE_ARN"
[ "$APPLY" = "1" ] || say "DRY RUN — nothing changed. Re-run with --apply to make it so."
