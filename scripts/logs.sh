#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yml" logs -f mihomo subscription-sync
