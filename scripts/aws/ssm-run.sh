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
        echo "::error::AWS credentials expired while waiting on SSM command $cmd_id."
        echo "::error::The command may still be RUNNING on the box — this is a"
        echo "::error::credential lifetime problem, not a build failure. See #62."
        status="CredentialsExpired"
        break ;;
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
