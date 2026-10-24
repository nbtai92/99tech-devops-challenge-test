#!/usr/bin/env bash
set -euo pipefail
id -u backend >/dev/null 2>&1 || useradd --system --home /opt/backend --shell /usr/sbin/nologin backend
mkdir -p /opt/backend/app /etc/backend
# Remove files of the previous revision so deleted files don't linger.
find /opt/backend/app -mindepth 1 -delete
