#!/usr/bin/env bash
# Integration check: can a browser on the frontend origin call the backend?
#   check-cors.sh <backend-url> <frontend-origin>
set -euo pipefail
backend="$1"; origin="${2%/}"

headers="$(curl -sS --max-time 10 -o /dev/null -D - -H "Origin: ${origin}" "${backend}/api/hello")"
status="$(printf '%s' "$headers" | awk 'NR==1{print $2}')"
allow="$(printf '%s' "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')"

if [ "$status" != "200" ]; then
  echo "::error::${backend}/api/hello returned ${status:-no response}"; exit 1
fi
if [ "$allow" != "$origin" ]; then
  echo "::error::backend does not allow origin ${origin} (Access-Control-Allow-Origin='${allow}'). Check CORS_ALLOWED_ORIGINS on the instances."
  exit 1
fi
echo "OK: ${origin} can call ${backend}/api/hello"
