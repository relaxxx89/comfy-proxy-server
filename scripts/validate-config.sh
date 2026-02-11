#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${ROOT_DIR}/scripts/render-config.sh"
"${ROOT_DIR}/scripts/sync-subscription.sh" || true

docker run --rm \
  -v "${ROOT_DIR}/runtime:/root/.config/mihomo" \
  docker.io/metacubex/mihomo:latest \
  -d /root/.config/mihomo \
  -f /root/.config/mihomo/config.yaml \
  -t
