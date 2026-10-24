#!/usr/bin/env bash
set -euo pipefail
install -m 0644 /opt/backend/app/deploy/backend.service /etc/systemd/system/backend.service
systemctl daemon-reload
chown -R backend:backend /opt/backend/app
