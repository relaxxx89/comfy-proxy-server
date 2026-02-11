#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${ROOT_DIR}/scripts/render-config.sh"
"${ROOT_DIR}/scripts/sync-subscription.sh" || true
docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yml" up -d
