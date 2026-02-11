#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  curl --fail --silent --show-error \
  --proxy "http://${PROXY_AUTH}@127.0.0.1:${PROXY_PORT}" \
  https://api.ipify.org
echo
