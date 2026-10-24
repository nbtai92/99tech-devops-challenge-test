#!/usr/bin/env bash
# Waits for AWS CodeDeploy using the deployment's *real* status instead of
# `aws deploy wait`, which cannot tell a failed deployment from a waiter timeout
# or an API error.
#
#   codedeploy-wait.sh idle <application> <group> <timeout-s>
#       Wait until the group has no active deployment (e.g. one left running by
#       a cancelled job, or an automatic rollback still in progress).
#   codedeploy-wait.sh deployment <deployment-id> <timeout-s>
#       Exit 0 only if the deployment Succeeded. Otherwise, exit 1 *after* AWS has
#       stopped deploying: a timed-out deployment is stopped with rollback, and
#       the automatic rollback deployment is followed until it finishes too.
#
# Env: POLL_INTERVAL (default 15), STOP_TIMEOUT (300), ROLLBACK_TIMEOUT (900)
set -uo pipefail

interval="${POLL_INTERVAL:-15}"

log() { echo "$*" >&2; }

status_of() {
  aws deploy get-deployment --deployment-id "$1" --query deploymentInfo.status --output text 2>/dev/null
}

# Prints the terminal status (Succeeded|Failed|Stopped), or TIMEOUT / UNKNOWN.
wait_terminal() {
  local id="$1" deadline=$(( $(date +%s) + $2 )) st errors=0
  while :; do
    st="$(status_of "$id")" || st=""
    case "$st" in
      Succeeded|Failed|Stopped) echo "$st"; return 0 ;;
      "") errors=$((errors + 1))
          log "warning: could not read status of $id (attempt $errors)"
          if [ "$errors" -ge 10 ]; then echo UNKNOWN; return 1; fi ;;
      *)  errors=0; log "$id: $st" ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then echo TIMEOUT; return 1; fi
    sleep "$interval"
  done
}

rollback_id_of() {
  aws deploy get-deployment --deployment-id "$1" \
    --query deploymentInfo.rollbackInfo.rollbackDeploymentId --output text 2>/dev/null
}

cmd_idle() {
  local app="$1" group="$2" timeout="$3" active id
  active="$(aws deploy list-deployments --application-name "$app" --deployment-group-name "$group" \
    --include-only-statuses Created Queued InProgress Ready --query deployments --output text)" || {
    echo "::error::cannot list deployments for $app/$group"; return 1; }
  for id in $active; do
    [ "$id" = "None" ] && continue
    log "waiting for active deployment $id to finish before starting a new one"
    case "$(wait_terminal "$id" "$timeout")" in
      Succeeded|Failed|Stopped) ;;
      *) echo "::error::deployment $id is still active; refusing to start another one"; return 1 ;;
    esac
  done
  return 0
}

cmd_deployment() {
  local id="$1" timeout="$2" final rb rbst
  final="$(wait_terminal "$id" "$timeout")"

  if [ "$final" = "Succeeded" ]; then
    echo "Deployment $id succeeded."
    return 0
  fi

  if [ "$final" = "TIMEOUT" ] || [ "$final" = "UNKNOWN" ]; then
    echo "::warning::Deployment $id did not finish ($final). Stopping it with automatic rollback."
    aws deploy stop-deployment --deployment-id "$id" --auto-rollback-enabled >/dev/null || true
    final="$(wait_terminal "$id" "${STOP_TIMEOUT:-300}")"
  fi

  aws deploy get-deployment --deployment-id "$id" \
    --query 'deploymentInfo.{status:status,error:errorInformation,rollback:rollbackInfo}' --output json || true

  # The rollback deployment can take a moment to be created after the failure.
  rb=""
  for _ in 1 2 3 4; do
    rb="$(rollback_id_of "$id")" || rb=""
    if [ -n "$rb" ] && [ "$rb" != "None" ]; then break; fi
    rb=""; sleep "$interval"
  done

  if [ -z "$rb" ]; then
    echo "::error::Deployment $id ended as $final with no automatic rollback (e.g. no previous revision). Manual intervention required."
    return 1
  fi

  log "following automatic rollback deployment $rb"
  rbst="$(wait_terminal "$rb" "${ROLLBACK_TIMEOUT:-900}")"
  if [ "$rbst" = "Succeeded" ]; then
    echo "::error::Deployment $id ended as $final. Automatic rollback $rb succeeded: the previous revision is serving."
  else
    echo "::error::Deployment $id ended as $final AND rollback $rb ended as $rbst. Manual intervention required."
  fi
  return 1
}

case "${1:-}" in
  idle)       shift; cmd_idle "$@" ;;
  deployment) shift; cmd_deployment "$@" ;;
  *) echo "usage: $0 idle <app> <group> <timeout-s> | deployment <id> <timeout-s>" >&2; exit 2 ;;
esac
