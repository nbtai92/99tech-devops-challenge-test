#!/usr/bin/env bash
set -euo pipefail
systemctl enable backend.service
systemctl restart backend.service
