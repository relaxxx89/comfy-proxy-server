#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_DIR="${ROOT_DIR}/runtime/.sync.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
SYNC_PID=""
INTERRUPTING=0
INTERRUPT_GRACE_SEC=3
ALLOW_DEGRADED_START=0

if [[ "${1:-}" == "--allow-degraded-start" ]]; then
  ALLOW_DEGRADED_START=1
  shift
fi

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--allow-degraded-start]" >&2
  exit 1
fi

cleanup_sync_lock_if_owned() {
  if [[ -z "${SYNC_PID}" ]]; then
    return 0
  fi

  local lock_pid=""
  if [[ -f "${LOCK_PID_FILE}" ]]; then
    lock_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
  fi

  if [[ -n "${lock_pid}" && "${lock_pid}" != "${SYNC_PID}" ]]; then
    return 0
  fi

  rm -f "${LOCK_PID_FILE}" >/dev/null 2>&1 || true
  rm -rf "${LOCK_DIR}" >/dev/null 2>&1 || true
}

stop_sync_process() {
  if [[ -z "${SYNC_PID}" ]]; then
    return 0
  fi

  kill -TERM "${SYNC_PID}" >/dev/null 2>&1 || true

  local waited=0
  while [[ "${waited}" -lt "${INTERRUPT_GRACE_SEC}" ]]; do
    if ! kill -0 "${SYNC_PID}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "${SYNC_PID}" >/dev/null 2>&1; then
    kill -KILL "${SYNC_PID}" >/dev/null 2>&1 || true
  fi

  wait "${SYNC_PID}" >/dev/null 2>&1 || true
  cleanup_sync_lock_if_owned
  SYNC_PID=""
}

on_interrupt() {
  local signal_name="$1"
  if [[ "${INTERRUPTING}" -eq 1 ]]; then
    exit 130
  fi
  INTERRUPTING=1
  stop_sync_process
  exit 130
}

on_exit() {
  stop_sync_process
}

trap on_exit EXIT
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM

"${ROOT_DIR}/scripts/render-config.sh"
"${ROOT_DIR}/scripts/sync-subscription.sh" &
SYNC_PID=$!
set +e
wait "${SYNC_PID}"
SYNC_RC=$?
set -e
cleanup_sync_lock_if_owned
SYNC_PID=""

if [[ "${SYNC_RC}" -ne 0 && "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
  echo "Initial subscription sync failed with exit code ${SYNC_RC}. Use --allow-degraded-start to continue anyway." >&2
  exit "${SYNC_RC}"
fi

if [[ "${SYNC_RC}" -ne 0 ]]; then
  echo "Initial subscription sync failed (exit ${SYNC_RC}); continuing due to --allow-degraded-start." >&2
fi

docker compose --env-file "${ROOT_DIR}/.env" -f "${ROOT_DIR}/docker-compose.yml" up -d --build
