#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/runtime"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB="${ROOT_DIR}/scripts/lib/env.sh"
CLEANUP_SCRIPT="${ROOT_DIR}/scripts/cleanup-runtime.sh"
STATUS_FILE="${RUNTIME_DIR}/status.json"
METRICS_FILE="${RUNTIME_DIR}/metrics.json"
sync_pid=""
worker_stopping=0
INTERRUPT_GRACE_SEC="${WORKER_INTERRUPT_GRACE_SEC:-15}"
consecutive_failures=0
last_success_at=""
last_failure_at=""
last_error_reason="not_run"
owner_uid_gid=""

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

if [ ! -f "${ENV_LIB}" ]; then
  echo "Missing ${ENV_LIB}." >&2
  exit 1
fi

mkdir -p "${RUNTIME_DIR}"

# shellcheck disable=SC1091
. "${ENV_LIB}"

log() {
  printf '[subscription-worker] %s\n' "$*" >&2
}

case "${INTERRUPT_GRACE_SEC}" in
  ''|*[!0-9]*)
    INTERRUPT_GRACE_SEC=15
    ;;
esac
if [ "${INTERRUPT_GRACE_SEC}" -le 0 ]; then
  INTERRUPT_GRACE_SEC=15
fi

fix_owner() {
  target_file="$1"
  if [ -z "${owner_uid_gid}" ]; then
    return 0
  fi
  if [ ! -e "${target_file}" ]; then
    return 0
  fi
  if ! command -v chown >/dev/null 2>&1; then
    return 0
  fi
  chown "${owner_uid_gid}" "${target_file}" >/dev/null 2>&1 || true
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

read_sync_reason() {
  if [ ! -f "${STATUS_FILE}" ]; then
    printf 'status_file_missing\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    reason="$(jq -r '.reason // ""' "${STATUS_FILE}" 2>/dev/null || true)"
    if [ -n "${reason}" ] && [ "${reason}" != "null" ]; then
      printf '%s\n' "${reason}"
      return 0
    fi
  fi

  reason="$(sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STATUS_FILE}" 2>/dev/null | head -n 1)"
  if [ -n "${reason}" ]; then
    printf '%s\n' "${reason}"
    return 0
  fi

  printf 'unknown\n'
  return 0
}

read_sync_status() {
  if [ ! -f "${STATUS_FILE}" ]; then
    printf 'status_file_missing\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    sync_status="$(jq -r '.status // ""' "${STATUS_FILE}" 2>/dev/null || true)"
    if [ -n "${sync_status}" ] && [ "${sync_status}" != "null" ]; then
      printf '%s\n' "${sync_status}"
      return 0
    fi
  fi

  sync_status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STATUS_FILE}" 2>/dev/null | head -n 1)"
  if [ -n "${sync_status}" ]; then
    printf '%s\n' "${sync_status}"
    return 0
  fi

  printf 'unknown\n'
  return 0
}

write_metrics() {
  worker_status="$1"
  reason="$2"
  updated_at="$(timestamp_utc)"
  reason_escaped="$(json_escape "${reason}")"
  status_escaped="$(json_escape "${worker_status}")"
  last_success_escaped="$(json_escape "${last_success_at}")"
  last_failure_escaped="$(json_escape "${last_failure_at}")"
  last_error_escaped="$(json_escape "${last_error_reason}")"

  metrics_tmp="${METRICS_FILE}.tmp.$$"
  cat > "${metrics_tmp}" <<EOF
{
  "updated_at": "${updated_at}",
  "status": "${status_escaped}",
  "consecutive_failures": ${consecutive_failures},
  "last_success_at": "${last_success_escaped}",
  "last_failure_at": "${last_failure_escaped}",
  "last_error_reason": "${last_error_escaped}",
  "reason": "${reason_escaped}"
}
EOF
  mv "${metrics_tmp}" "${METRICS_FILE}"
  fix_owner "${METRICS_FILE}"
}

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

owner_uid_gid="$(stat -c '%u:%g' "${RUNTIME_DIR}" 2>/dev/null || true)"

write_metrics "starting" "worker_boot"

while :; do
  if [ -x "${CLEANUP_SCRIPT}" ]; then
    "${CLEANUP_SCRIPT}" --hours 24 --quiet >/dev/null 2>&1 || true
  fi

  SYNC_INVOKER=worker "${ROOT_DIR}/scripts/sync-subscription.sh" &
  sync_pid=$!
  set +e
  wait "${sync_pid}"
  sync_rc=$?
  set -e
  sync_pid=""

  sync_status="$(read_sync_status)"
  sync_reason="$(read_sync_reason)"

  if [ "${sync_rc}" -eq 0 ] && [ "${sync_status}" = "healthy" ]; then
    consecutive_failures=0
    last_success_at="$(timestamp_utc)"
    last_error_reason="ok"
    write_metrics "healthy" "ok"
  else
    consecutive_failures=$((consecutive_failures + 1))
    last_failure_at="$(timestamp_utc)"
    if [ "${sync_reason}" = "" ]; then
      sync_reason="unknown"
    fi
    last_error_reason="${sync_reason}"
    write_metrics "degraded" "${sync_reason}"
    log "sync degraded (rc=${sync_rc}, status=${sync_status}, reason=${sync_reason}, consecutive_failures=${consecutive_failures})"
  fi

  if ! load_env_file "${ENV_FILE}"; then
    log "failed to load ${ENV_FILE}; using default SANITIZE_INTERVAL=300."
  fi

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
