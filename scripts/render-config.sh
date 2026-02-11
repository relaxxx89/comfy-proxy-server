#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE_FILE="${ROOT_DIR}/config/mihomo.template.yaml"
RUNTIME_DIR="${ROOT_DIR}/runtime"
OUTPUT_FILE="${RUNTIME_DIR}/config.yaml"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

required_vars=(
  SUBSCRIPTION_URL
  LAN_BIND_IP
  PROXY_PORT
  PROXY_AUTH
  API_BIND
  API_SECRET
  MIHOMO_LOG_LEVEL
  HEALTHCHECK_URL
  HEALTHCHECK_INTERVAL
  HEALTHCHECK_TIMEOUT
  URL_TEST_INTERVAL
  URL_TEST_TOLERANCE
  FALLBACK_INTERVAL
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Required variable ${var_name} is empty in ${ENV_FILE}" >&2
    exit 1
  fi
done

mkdir -p "${RUNTIME_DIR}/proxy_providers"

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

content="$(cat "${TEMPLATE_FILE}")"
for var_name in "${required_vars[@]}"; do
  token="__${var_name}__"
  value="$(escape_sed "${!var_name}")"
  content="$(printf '%s' "${content}" | sed "s/${token}/${value}/g")"
done

printf '%s\n' "${content}" > "${OUTPUT_FILE}"
echo "Generated ${OUTPUT_FILE}"
