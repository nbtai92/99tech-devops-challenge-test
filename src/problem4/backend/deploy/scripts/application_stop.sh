#!/usr/bin/env bash
set -euo pipefail
# The very first deployment has no running service yet.
if systemctl list-unit-files backend.service >/dev/null 2>&1; then
  systemctl stop backend.service || true
fi
