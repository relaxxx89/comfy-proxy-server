#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB="${ROOT_DIR}/scripts/lib/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

if [[ ! -f "${ENV_LIB}" ]]; then
  echo "Missing ${ENV_LIB}." >&2
  exit 1
fi

# shellcheck disable=SC1091
. "${ENV_LIB}"
load_env_file "${ENV_FILE}"
require_env_vars PROXY_PORT PROXY_AUTH || exit 1

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  curl --fail --silent --show-error \
  --proxy "http://127.0.0.1:${PROXY_PORT}" \
  --proxy-user "${PROXY_AUTH}" \
  https://api.ipify.org
echo
