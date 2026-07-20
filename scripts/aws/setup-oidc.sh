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
ROLE_NAME="${ROLE_NAME:-displayxr-browser-build-box}"
POLICY_NAME="${POLICY_NAME:-displayxr-browser-build-box}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-displayxr-browser-artifacts}"

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }
say() { echo "[setup-oidc] $*"; }
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
  say "role $ROLE_NAME exists -> update trust policy"
  run aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST_FILE"
else
  say "role $ROLE_NAME MISSING -> create"
  run aws iam create-role --role-name "$ROLE_NAME" \
    --description "GitHub Actions (browser#34): drive the Chromium build box, no long-lived secret" \
    --assume-role-policy-document "file://$TRUST_FILE"
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
      "Sid": "DescribeInstancesReadOnly",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      "Resource": "*"
    },
    {
      "Sid": "StartStopTheBuildBoxOnly",
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
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"],
      "Resource": "*"
    },
    {
      "Sid": "ReadBuildArtifact",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${ARTIFACT_BUCKET}",
        "arn:aws:s3:::${ARTIFACT_BUCKET}/*"
      ]
    }
  ]
}
JSON
)
PERMS_FILE="$(mktemp)"; printf '%s' "$PERMS" > "$PERMS_FILE"
say "attach inline policy $POLICY_NAME to $ROLE_NAME"
run aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" --policy-document "file://$PERMS_FILE"

# ── 4. prerequisite checks (report only — these need instance-side changes) ───────────
say "--- prerequisite checks ---"
SSM_OK="$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"
if [ "$SSM_OK" = "Online" ]; then
  say "SSM: instance is Online (RunCommand will work)"
else
  say "SSM: instance NOT registered (PingStatus=${SSM_OK:-none})."
  say "     FIX: attach an instance profile with AmazonSSMManagedInstanceCore and ensure"
  say "     the SSM Agent runs. Without this the workflow cannot start the build remotely."
fi
if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
  say "S3: artifact bucket $ARTIFACT_BUCKET reachable"
else
  say "S3: bucket $ARTIFACT_BUCKET missing/unreachable."
  say "     FIX: create it, and give the INSTANCE role s3:PutObject on it so the build box"
  say "     can upload the tarball the workflow then downloads."
fi

echo
say "ROLE ARN (set as repo variable AWS_BUILD_ROLE_ARN): $ROLE_ARN"
[ "$APPLY" = "1" ] || say "DRY RUN — nothing changed. Re-run with --apply to make it so."
