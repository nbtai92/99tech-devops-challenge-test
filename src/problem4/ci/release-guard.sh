#!/usr/bin/env bash
# Prevents an older release from overwriting a newer one when pipeline runs
# finish out of order (e.g. commit A builds slowly and reaches deploy after B).
#
#   release-guard.sh <candidate-sha> <currently-deployed-sha-or-empty>
#
# Prints "deploy" or "skip". Must run inside a checkout with full history.
# Intentional rollbacks do not use this guard (mode: rollback).
set -euo pipefail

candidate="$1"
current="${2:-}"

if [ -z "$current" ] || [ "$current" = "None" ] || [ "$current" = "dev" ]; then
  echo "nothing deployed yet (or unknown) -> deploy" >&2; echo deploy; exit 0
fi
if [ "$current" = "$candidate" ]; then
  echo "$candidate is already deployed -> redeploy (idempotent)" >&2; echo deploy; exit 0
fi
if ! git cat-file -e "${current}^{commit}" 2>/dev/null; then
  echo "currently deployed $current is not in this repository's history -> deploy" >&2; echo deploy; exit 0
fi
if git merge-base --is-ancestor "$candidate" "$current"; then
  echo "currently deployed $current is newer than $candidate -> skip" >&2; echo skip; exit 0
fi
echo "$candidate is newer than (or diverged from) $current -> deploy" >&2
echo deploy
