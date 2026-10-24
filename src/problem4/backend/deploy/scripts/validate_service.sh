#!/usr/bin/env bash
# Wait until the new revision answers /health with the version we just deployed.
set -euo pipefail
expected="$(cat /opt/backend/app/VERSION)"
for _ in $(seq 1 30); do
  body="$(curl -fsS --max-time 2 http://127.0.0.1:3000/health || true)"
  if [[ "$body" == *"\"version\":\"${expected}\""* ]]; then
    echo "healthy: $body"
    exit 0
  fi
  sleep 2
done
echo "backend did not become healthy with version ${expected}" >&2
journalctl -u backend.service -n 50 --no-pager >&2 || true
exit 1
