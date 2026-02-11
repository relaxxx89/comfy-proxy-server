#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
sync_pid=""
worker_stopping=0
INTERRUPT_GRACE_SEC=3

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

stop_current_sync() {
  if [ -z "${sync_pid}" ]; then
    return 0
  fi

  kill -TERM "${sync_pid}" >/dev/null 2>&1 || true

  waited=0
  while [ "${waited}" -lt "${INTERRUPT_GRACE_SEC}" ]; do
    if ! kill -0 "${sync_pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "${sync_pid}" >/dev/null 2>&1; then
    kill -KILL "${sync_pid}" >/dev/null 2>&1 || true
  fi

  wait "${sync_pid}" >/dev/null 2>&1 || true
  sync_pid=""
}

on_interrupt() {
  signal_name="$1"
  if [ "${worker_stopping}" -eq 1 ]; then
    exit 130
  fi
  worker_stopping=1
  stop_current_sync
  exit 130
}

cleanup_worker() {
  stop_current_sync
}

trap cleanup_worker EXIT
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM

while :; do
  "${ROOT_DIR}/scripts/sync-subscription.sh" &
  sync_pid=$!
  wait "${sync_pid}" || true
  sync_pid=""

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
