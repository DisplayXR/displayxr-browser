#!/usr/bin/env bash
# ssm-run.sh - send PowerShell to the build box over SSM, wait for it, surface its output.
# Reads the commands from stdin, one per line. Used by .github/workflows/build-box.yml.
#
# Usage:  printf '%s\n' 'Get-Date' | ssm-run.sh <instance-id> "<comment>" <timeout-minutes>
#
# Two things this exists to get right:
#
#  1. QUOTING. The commands are handed to `aws ssm send-command` as a JSON parameter file
#     built by jq, never as an inline shell-quoted string. PowerShell is full of backslashes
#     and double quotes, and building that JSON by hand in YAML -> bash -> JSON is how you
#     get `C:\build` silently becoming `C:uild`. Do not "simplify" this back to
#     --parameters commands="[...]".
#
#  2. executionTimeout. AWS-RunPowerShellScript defaults to 3600s, so a 90-minute Chromium
#     build would be killed at the one-hour mark and reported as a *build* failure. We set it
#     from the caller's timeout plus a margin.
#
# Exit status mirrors the invocation: 0 only if SSM reports Success.
set -uo pipefail

# --- credential refresh -------------------------------------------------------
# The OIDC session minted at the top of the job lasts MaxSessionDuration, which is
# the default 3600s on this role. A rebase or build routinely runs longer, so the
# poll loop below would lose the ability to read the command's status mid-wait and
# the whole run would die at the one-hour mark with the command still healthy on
# the box (#62, seen twice).
#
# Re-mint instead of dying. `assume-role-with-web-identity` is an UNSIGNED call, so
# it works even though the credentials we currently hold are already expired — that
# is what makes this recoverable rather than a chicken-and-egg problem. The GitHub
# OIDC token endpoint stays available for the life of the job.
#
# Requires AWS_BUILD_ROLE_ARN in the environment plus the job's `id-token: write`.
# Degrades to the old behaviour (abort with a clear message) if either is absent,
# so this stays usable outside Actions.
refresh_aws_creds() {
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || return 1
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || return 1
  [ -n "${AWS_BUILD_ROLE_ARN:-}" ] || return 1
  local tok creds
  tok="$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN"          "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com"          | jq -r '.value // empty')" || return 1
  [ -n "$tok" ] || return 1
  creds="$(aws sts assume-role-with-web-identity             --role-arn "$AWS_BUILD_ROLE_ARN"             --role-session-name "ssm-run-refresh-$$"             --web-identity-token "$tok"             --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'             --output text 2>/dev/null)" || return 1
  [ -n "$creds" ] || return 1
  export AWS_ACCESS_KEY_ID="$(printf '%s' "$creds" | cut -f1)"
  export AWS_SECRET_ACCESS_KEY="$(printf '%s' "$creds" | cut -f2)"
  export AWS_SESSION_TOKEN="$(printf '%s' "$creds" | cut -f3)"
  return 0
}

INSTANCE_ID="${1:?instance id required}"
COMMENT="${2:-ssm-run}"
TIMEOUT_MIN="${3:-60}"

# Margin over the caller's own timeout so the *script* reports the timeout (with a status
# tail) rather than SSM guillotining it with no diagnostics.
EXEC_TIMEOUT=$(( TIMEOUT_MIN * 60 + 900 ))

params="$(mktemp)"
jq -R -s --arg t "$EXEC_TIMEOUT" \
  'split("\n") | map(select(length > 0)) | {commands: ., executionTimeout: [$t]}' \
  > "$params"

cmd_id="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunPowerShellScript" \
  --comment "$COMMENT" \
  --parameters "file://$params" \
  --query 'Command.CommandId' --output text)" || {
    echo "::error::ssm send-command failed"; exit 1; }
echo "ssm command: $cmd_id"

deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 + 600 ))
status=Pending
# Consecutive poll failures. This used to be `2>/dev/null || echo Pending`, which
# reported EVERY API failure as the literal status "Pending" — including
# ExpiredTokenException once the OIDC session aged out at one hour (#62). The
# result was a run that appeared to sit in "Pending" for 70 minutes and a
# "gave up waiting (last status: Pending)" verdict that pointed at the SSM agent,
# when the truth was that we had simply stopped being able to READ the status.
# Never conflate "cannot query" with "not started".
poll_errs=0
while :; do
  if ! status_out="$(aws ssm get-command-invocation --command-id "$cmd_id" \
                     --instance-id "$INSTANCE_ID" --query Status --output text 2>&1)"; then
    poll_errs=$(( poll_errs + 1 ))
    echo "  [poll] get-command-invocation failed (${poll_errs}): ${status_out}"
    # Credentials dying mid-run is terminal for this job — every later call,
    # including "Stop the build box", will fail the same way. Say so once, loudly,
    # instead of burning the rest of the timeout on calls that cannot succeed.
    case "$status_out" in
      *ExpiredToken*|*RequestExpired*|*InvalidClientTokenId*|*credentials*)
        # Do NOT give up — the command is very probably still running fine on the
        # box; we have merely aged out of our session. Re-mint and carry on.
        if refresh_aws_creds; then
          echo "  [poll] credentials expired -> re-minted via OIDC; continuing to wait"
          poll_errs=0
        else
          echo "::error::AWS credentials expired while waiting on SSM command $cmd_id,"
          echo "::error::and could not be refreshed (need AWS_BUILD_ROLE_ARN +"
          echo "::error::id-token: write). The command may still be RUNNING on the box —"
          echo "::error::this is a credential lifetime problem, not a build failure."
          status="CredentialsExpired"
          break
        fi ;;
    esac
    if [ "$poll_errs" -ge 5 ]; then
      echo "::error::5 consecutive SSM status queries failed; giving up on $cmd_id"
      status="PollFailed"
      break
    fi
  else
    poll_errs=0
    status="$status_out"
  fi
  case "$status" in
    Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated) break ;;
  esac
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "::error::gave up waiting on SSM command $cmd_id (last status: $status)"
    break
  fi
  sleep 30
done

echo "--- stdout ---"
aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text || true
err="$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
       --query 'StandardErrorContent' --output text 2>/dev/null || true)"
if [ -n "$err" ] && [ "$err" != "None" ]; then
  echo "--- stderr ---"; echo "$err"
fi

echo "ssm status: $status"
[ "$status" = "Success" ] || exit 1
