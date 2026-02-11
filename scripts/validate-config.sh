#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_DIR="${ROOT_DIR}/runtime/.sync.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
SYNC_PID=""
INTERRUPTING=0
INTERRUPT_GRACE_SEC=3

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
wait "${SYNC_PID}" || true
cleanup_sync_lock_if_owned
SYNC_PID=""

docker run --rm \
  -v "${ROOT_DIR}/runtime:/root/.config/mihomo" \
  docker.io/metacubex/mihomo:latest \
  -d /root/.config/mihomo \
  -f /root/.config/mihomo/config.yaml \
  -t
