#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB="${ROOT_DIR}/scripts/lib/env.sh"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
STATUS_FILE="${ROOT_DIR}/runtime/status.json"
MIHOMO_SERVICE="mihomo"
DOCKER_SOCKET_PROXY_SERVICE="docker-socket-proxy"
SYNC_SERVICE="subscription-sync"
ALLOW_DEGRADED_START=0
API_READY_TIMEOUT_SEC=45
STATUS_REFRESH_TIMEOUT_SEC=120
WORKER_RECOVER_ON_EXIT=0

if [[ "${1:-}" == "--allow-degraded-start" ]]; then
  ALLOW_DEGRADED_START=1
  shift
fi

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--allow-degraded-start]" >&2
  exit 1
fi

if [[ ! -f "${ENV_LIB}" ]]; then
  echo "Missing ${ENV_LIB}." >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

# shellcheck disable=SC1091
. "${ENV_LIB}"
load_env_file "${ENV_FILE}"

API_BIND="${API_BIND:-127.0.0.1:9090}"
API_SECRET="${API_SECRET:-}"
THROUGHPUT_ENABLE="${THROUGHPUT_ENABLE:-true}"

log() {
  printf '[up] %s\n' "$*" >&2
}

compose_cmd() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

start_sync_worker() {
  compose_cmd up -d --no-deps "${SYNC_SERVICE}"
}

ensure_worker_running_on_exit() {
  if [[ "${WORKER_RECOVER_ON_EXIT}" -ne 1 ]]; then
    return 0
  fi

  set +e
  compose_cmd up -d --no-deps "${SYNC_SERVICE}" >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    log "Failed to restore ${SYNC_SERVICE} service after startup failure."
  fi
}

trap ensure_worker_running_on_exit EXIT

is_truthy() {
  case "$1" in
    true|TRUE|1|yes|YES)
      return 0
      ;;
  esac
  return 1
}

read_status_field() {
  local field="$1"

  if [[ ! -f "${STATUS_FILE}" ]]; then
    printf '\n'
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local value
    value="$(jq -r ".${field} // \"\"" "${STATUS_FILE}" 2>/dev/null || true)"
    if [[ -n "${value}" && "${value}" != "null" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${STATUS_FILE}" 2>/dev/null | head -n 1
}

api_ready_once() {
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  local api_url="http://${API_BIND}/version"
  if [[ -n "${API_SECRET}" ]]; then
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      curl --noproxy '*' --silent --show-error --fail \
      -H "Authorization: Bearer ${API_SECRET}" \
      "${api_url}" >/dev/null
  else
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      curl --noproxy '*' --silent --show-error --fail \
      "${api_url}" >/dev/null
  fi
}

wait_for_api_ready() {
  local deadline=$((SECONDS + API_READY_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if api_ready_once; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_initial_sync_one_shot() {
  local output
  local rc

  set +e
  output="$(compose_cmd run --rm -T --build --no-deps "${SYNC_SERVICE}" sh -lc 'SYNC_INVOKER=up ./scripts/sync-subscription.sh' 2>&1)"
  rc=$?
  set -e

  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}"
  fi

  return "${rc}"
}

wait_for_status_refresh() {
  local previous_fetch="$1"
  if [[ -z "${previous_fetch}" ]]; then
    return 0
  fi

  local deadline=$((SECONDS + STATUS_REFRESH_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    local current_fetch
    current_fetch="$(read_status_field "last_fetch")"
    if [[ -n "${current_fetch}" && "${current_fetch}" != "${previous_fetch}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

"${ROOT_DIR}/scripts/render-config.sh"
compose_cmd up -d --build "${MIHOMO_SERVICE}" "${DOCKER_SOCKET_PROXY_SERVICE}"

if ! wait_for_api_ready; then
  msg="Mihomo API (${API_BIND}) did not become ready within ${API_READY_TIMEOUT_SEC}s."
  if [[ "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
    echo "${msg}" >&2
    exit 1
  fi
  log "${msg} Continuing due to --allow-degraded-start."
fi

compose_cmd stop "${SYNC_SERVICE}" >/dev/null 2>&1 || true
WORKER_RECOVER_ON_EXIT=1

previous_fetch="$(read_status_field "last_fetch")"
if ! run_initial_sync_one_shot; then
  if [[ "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
    echo "Initial subscription sync failed in one-shot ${SYNC_SERVICE} run. Use --allow-degraded-start to continue anyway." >&2
    exit 1
  fi
  log "Initial subscription sync failed; continuing due to --allow-degraded-start."
fi

current_fetch="$(read_status_field "last_fetch")"
if [[ -n "${previous_fetch}" && "${current_fetch}" == "${previous_fetch}" ]]; then
  if ! wait_for_status_refresh "${previous_fetch}"; then
    msg="Did not observe a fresh sync status update within ${STATUS_REFRESH_TIMEOUT_SEC}s after startup."
    if [[ "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
      echo "${msg}" >&2
      exit 1
    fi
    log "${msg} Continuing due to --allow-degraded-start."
  fi
fi

final_status="$(read_status_field "status")"
final_reason="$(read_status_field "reason")"
final_throughput_reason="$(read_status_field "throughput_reason")"
final_last_fetch="$(read_status_field "last_fetch")"

if [[ "${final_status}" != "healthy" || "${final_reason}" != "ok" ]]; then
  msg="Initial status is not healthy: status=${final_status:-unknown} reason=${final_reason:-unknown} throughput_reason=${final_throughput_reason:-unknown}."
  if [[ "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
    echo "${msg}" >&2
    exit 1
  fi
  log "${msg} Continuing due to --allow-degraded-start."
fi

if is_truthy "${THROUGHPUT_ENABLE}" && [[ "${final_throughput_reason}" == "api_unreachable" ]]; then
  msg="Initial throughput ranking still reports api_unreachable; controller ${API_BIND} may be unstable."
  if [[ "${ALLOW_DEGRADED_START}" -ne 1 ]]; then
    echo "${msg}" >&2
    exit 1
  fi
  log "${msg} Continuing due to --allow-degraded-start."
fi

start_sync_worker
WORKER_RECOVER_ON_EXIT=0

log "Startup complete: status=${final_status:-unknown} reason=${final_reason:-unknown} throughput_reason=${final_throughput_reason:-unknown} fetched_at=${final_last_fetch:-unknown}."
