#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

while :; do
  "${ROOT_DIR}/scripts/sync-subscription.sh" || true

  # shellcheck disable=SC1090
  set -a
  . "${ENV_FILE}"
  set +a

  interval="${SANITIZE_INTERVAL:-300}"
  case "${interval}" in
    ''|*[!0-9]*)
      interval=300
      ;;
  esac
  if [ "${interval}" -le 0 ]; then
    interval=300
  fi

  sleep "${interval}"
done
