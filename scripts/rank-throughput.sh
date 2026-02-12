#!/usr/bin/env sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <input-provider-file> <output-ranked-file>" >&2
  exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_LIB="${ROOT_DIR}/scripts/lib/env.sh"
OUTPUT_DIR="$(CDPATH= cd -- "$(dirname -- "${OUTPUT_FILE}")" && pwd 2>/dev/null || true)"
owner_ref_path="${OUTPUT_DIR}"
if [ -z "${owner_ref_path}" ] || [ ! -d "${owner_ref_path}" ]; then
  owner_ref_path="${ROOT_DIR}/runtime"
fi
if [ ! -d "${owner_ref_path}" ]; then
  owner_ref_path="${ROOT_DIR}"
fi
owner_uid_gid="$(stat -c '%u:%g' "${owner_ref_path}" 2>/dev/null || true)"

throughput_tested=0
throughput_ranked=0
throughput_failed=0
throughput_reason="disabled"
throughput_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
bench_selector_last_error=""

print_metrics() {
  echo "THROUGHPUT_TESTED=${throughput_tested}"
  echo "THROUGHPUT_RANKED=${throughput_ranked}"
  echo "THROUGHPUT_FAILED=${throughput_failed}"
  echo "THROUGHPUT_REASON=${throughput_reason}"
  echo "THROUGHPUT_TIMESTAMP=${throughput_timestamp}"
}

log() {
  printf '[throughput-rank] %s\n' "$*" >&2
}

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

replace_file_from_source() {
  source_file="$1"
  target_file="$2"
  tmp_file="${target_file}.tmp.$$"
  cp "${source_file}" "${tmp_file}" || return 1
  mv "${tmp_file}" "${target_file}" || return 1
  fix_owner "${target_file}"
  return 0
}

replace_file_from_source "${INPUT_FILE}" "${OUTPUT_FILE}" 2>/dev/null || true

if [ ! -f "${ENV_FILE}" ]; then
  throughput_reason="missing_env"
  print_metrics
  exit 0
fi

if [ ! -f "${ENV_LIB}" ]; then
  throughput_reason="missing_env_lib"
  print_metrics
  exit 0
fi

# shellcheck disable=SC1091
. "${ENV_LIB}"
load_env_file "${ENV_FILE}"

THROUGHPUT_ENABLE="${THROUGHPUT_ENABLE:-true}"
THROUGHPUT_TOP_N="${THROUGHPUT_TOP_N:-50}"
THROUGHPUT_TEST_URL="${THROUGHPUT_TEST_URL:-https://speed.cloudflare.com/__down?bytes=5000000}"
THROUGHPUT_TIMEOUT_SEC="${THROUGHPUT_TIMEOUT_SEC:-12}"
THROUGHPUT_MIN_KBPS="${THROUGHPUT_MIN_KBPS:-50}"
THROUGHPUT_SAMPLES="${THROUGHPUT_SAMPLES:-3}"
THROUGHPUT_REQUIRED_SUCCESSES="${THROUGHPUT_REQUIRED_SUCCESSES:-0}"
THROUGHPUT_ISOLATED="${THROUGHPUT_ISOLATED:-true}"
THROUGHPUT_BENCH_PROXY_PORT="${THROUGHPUT_BENCH_PROXY_PORT:-17890}"
THROUGHPUT_BENCH_API_PORT="${THROUGHPUT_BENCH_API_PORT:-19090}"
THROUGHPUT_BENCH_DYNAMIC_PORTS="${THROUGHPUT_BENCH_DYNAMIC_PORTS:-true}"
THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC="${THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC:-20}"
THROUGHPUT_BENCH_API_SECRET="${THROUGHPUT_BENCH_API_SECRET:-bench-secret-$$}"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_AUTH="${PROXY_AUTH:-}"
API_BIND="${API_BIND:-127.0.0.1:9090}"
API_SECRET="${API_SECRET:-}"
MIHOMO_IMAGE="${MIHOMO_IMAGE:-docker.io/metacubex/mihomo:latest}"

case "${THROUGHPUT_ENABLE}" in
  true|TRUE|1|yes|YES)
    ;;
  *)
    throughput_reason="disabled"
    print_metrics
    exit 0
    ;;
esac

if [ ! -s "${INPUT_FILE}" ]; then
  throughput_reason="empty_input"
  print_metrics
  exit 0
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  throughput_reason="tools_missing"
  print_metrics
  exit 0
fi

case "${THROUGHPUT_TOP_N}" in
  ''|*[!0-9]*)
    THROUGHPUT_TOP_N=50
    ;;
esac
if [ "${THROUGHPUT_TOP_N}" -le 0 ]; then
  THROUGHPUT_TOP_N=50
fi

case "${THROUGHPUT_TIMEOUT_SEC}" in
  ''|*[!0-9]*)
    THROUGHPUT_TIMEOUT_SEC=12
    ;;
esac
if [ "${THROUGHPUT_TIMEOUT_SEC}" -le 0 ]; then
  THROUGHPUT_TIMEOUT_SEC=12
fi

case "${THROUGHPUT_MIN_KBPS}" in
  ''|*[!0-9]*)
    THROUGHPUT_MIN_KBPS=50
    ;;
esac
if [ "${THROUGHPUT_MIN_KBPS}" -lt 0 ]; then
  THROUGHPUT_MIN_KBPS=0
fi

case "${THROUGHPUT_SAMPLES}" in
  ''|*[!0-9]*)
    THROUGHPUT_SAMPLES=3
    ;;
esac
if [ "${THROUGHPUT_SAMPLES}" -le 0 ]; then
  THROUGHPUT_SAMPLES=3
fi

case "${THROUGHPUT_REQUIRED_SUCCESSES}" in
  ''|*[!0-9]*)
    THROUGHPUT_REQUIRED_SUCCESSES=0
    ;;
esac
if [ "${THROUGHPUT_REQUIRED_SUCCESSES}" -le 0 ] || [ "${THROUGHPUT_REQUIRED_SUCCESSES}" -gt "${THROUGHPUT_SAMPLES}" ]; then
  THROUGHPUT_REQUIRED_SUCCESSES=$((THROUGHPUT_SAMPLES / 2 + 1))
fi

case "${THROUGHPUT_ISOLATED}" in
  true|TRUE|1|yes|YES)
    THROUGHPUT_ISOLATED=true
    ;;
  *)
    THROUGHPUT_ISOLATED=false
    ;;
esac

case "${THROUGHPUT_BENCH_DYNAMIC_PORTS}" in
  true|TRUE|1|yes|YES)
    THROUGHPUT_BENCH_DYNAMIC_PORTS=true
    ;;
  *)
    THROUGHPUT_BENCH_DYNAMIC_PORTS=false
    ;;
esac

case "${THROUGHPUT_BENCH_PROXY_PORT}" in
  ''|*[!0-9]*)
    THROUGHPUT_BENCH_PROXY_PORT=17890
    ;;
esac
if [ "${THROUGHPUT_BENCH_PROXY_PORT}" -le 0 ]; then
  THROUGHPUT_BENCH_PROXY_PORT=17890
fi

case "${THROUGHPUT_BENCH_API_PORT}" in
  ''|*[!0-9]*)
    THROUGHPUT_BENCH_API_PORT=19090
    ;;
esac
if [ "${THROUGHPUT_BENCH_API_PORT}" -le 0 ]; then
  THROUGHPUT_BENCH_API_PORT=19090
fi

case "${THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC}" in
  ''|*[!0-9]*)
    THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC=20
    ;;
esac
if [ "${THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC}" -le 0 ]; then
  THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC=20
fi

MIN_BPS=$((THROUGHPUT_MIN_KBPS * 1024))
TMP_DIR="$(mktemp -d "/tmp/mihomo-rank.XXXXXX" 2>/dev/null || mktemp -d "${ROOT_DIR}/runtime/rank.XXXXXX")"
PROXY_STATE_FILE="${TMP_DIR}/proxy-state.json"
PROXY_ALL_FILE="${TMP_DIR}/proxy-all.txt"
CANDIDATE_SPEEDS_FILE="${TMP_DIR}/candidate-speeds.txt"
BENCH_CONFIG_FILE="${TMP_DIR}/bench-config.yaml"
BENCH_PROVIDER_FILE="${TMP_DIR}/candidate.txt"
current_proxy="AUTO_FAILSAFE"
restore_target="AUTO_FAILSAFE"
proxy_switched_to_bench=0
cleanup_done=0
bench_container_name=""
bench_proxy_port="${THROUGHPUT_BENCH_PROXY_PORT}"
bench_api_port="${THROUGHPUT_BENCH_API_PORT}"

api_base=""
auth_header=""

api_call() {
  method="$1"
  endpoint="$2"
  body="${3:-}"
  if [ -n "${auth_header}" ]; then
    if [ -n "${body}" ]; then
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --noproxy '*' --silent --show-error --fail \
        -X "${method}" \
        -H "${auth_header}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${api_base}${endpoint}"
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --noproxy '*' --silent --show-error --fail \
        -X "${method}" \
        -H "${auth_header}" \
        "${api_base}${endpoint}"
    fi
  else
    if [ -n "${body}" ]; then
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --noproxy '*' --silent --show-error --fail \
        -X "${method}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${api_base}${endpoint}"
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --noproxy '*' --silent --show-error --fail \
        -X "${method}" \
        "${api_base}${endpoint}"
    fi
  fi
}

setup_api_context() {
  api_base="$1"
  api_secret="$2"
  if [ -n "${api_secret}" ]; then
    auth_header="Authorization: Bearer ${api_secret}"
  else
    auth_header=""
  fi
}

error_summary() {
  printf '%s' "$1" \
    | tr '\n' ' ' \
    | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | cut -c1-400
}

port_in_use() {
  port="$1"
  case "${port}" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk -v p="${port}" '
    NR > 1 {
      addr = $4
      sub(/^.*:/, "", addr)
      if (addr == p) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
    '; then
      return 0
    fi
    return 1
  fi

  port_hex="$(printf '%04X' "${port}" 2>/dev/null || true)"
  if [ -z "${port_hex}" ]; then
    return 0
  fi

  if awk -v ph="${port_hex}" '
  FNR == 1 { next }
  {
    split($2, a, ":")
    if (toupper(a[2]) == ph) {
      found = 1
      exit
    }
  }
  END { exit found ? 0 : 1 }
  ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    return 0
  fi
  return 1
}

find_free_port() {
  range_start="$1"
  range_end="$2"
  avoid_port="${3:-}"
  port="${range_start}"

  while [ "${port}" -le "${range_end}" ]; do
    if [ -n "${avoid_port}" ] && [ "${port}" -eq "${avoid_port}" ]; then
      port=$((port + 1))
      continue
    fi
    if ! port_in_use "${port}"; then
      printf '%s\n' "${port}"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

resolve_bench_ports() {
  bench_proxy_port="${THROUGHPUT_BENCH_PROXY_PORT}"
  bench_api_port="${THROUGHPUT_BENCH_API_PORT}"

  if [ "${THROUGHPUT_BENCH_DYNAMIC_PORTS}" = "true" ]; then
    bench_proxy_port="$(find_free_port 17890 18890 "")" || {
      throughput_reason="bench_runtime_port_conflict"
      log "Failed to allocate free bench proxy port in 17890-18890."
      return 1
    }
    bench_api_port="$(find_free_port 19090 20090 "${bench_proxy_port}")" || {
      throughput_reason="bench_runtime_port_conflict"
      log "Failed to allocate free bench API port in 19090-20090."
      return 1
    }
    return 0
  fi

  if port_in_use "${bench_proxy_port}"; then
    throughput_reason="bench_runtime_port_conflict"
    log "Configured bench proxy port ${bench_proxy_port} is already in use."
    return 1
  fi
  if port_in_use "${bench_api_port}"; then
    throughput_reason="bench_runtime_port_conflict"
    log "Configured bench API port ${bench_api_port} is already in use."
    return 1
  fi
  return 0
}

cleanup_orphan_bench_containers() {
  stale_ids="$(docker ps -aq --filter "name=mihomo-throughput-" 2>/dev/null || true)"
  if [ -z "${stale_ids}" ]; then
    return 0
  fi

  cleaned=0
  for stale_id in ${stale_ids}; do
    stale_status="$(docker inspect -f '{{.State.Status}}' "${stale_id}" 2>/dev/null || true)"
    case "${stale_status}" in
      running)
        continue
        ;;
    esac
    run_bench_docker docker rm -fv "${stale_id}" >/dev/null 2>&1 || true
    cleaned=$((cleaned + 1))
  done

  if [ "${cleaned}" -gt 0 ]; then
    log "Cleaned up ${cleaned} orphan bench container(s)."
  fi
  return 0
}

bench_selector_ready_once() {
  if ! api_call GET "/proxies/PROXY" > "${PROXY_STATE_FILE}" 2>/dev/null; then
    bench_selector_last_error="selector_unreachable"
    return 1
  fi

  if ! jq -e '.all | type == "array"' "${PROXY_STATE_FILE}" >/dev/null 2>&1; then
    bench_selector_last_error="selector_all_missing"
    return 1
  fi

  if ! jq -e '.all[]? | select(. == "BENCH")' "${PROXY_STATE_FILE}" >/dev/null 2>&1; then
    bench_selector_last_error="bench_missing"
    return 1
  fi

  bench_selector_last_error=""
  return 0
}

wait_for_bench_selector_ready() {
  timeout_sec="$1"
  interval_sec="$2"
  case "${timeout_sec}" in
    ''|*[!0-9]*)
      timeout_sec=1
      ;;
  esac
  if [ "${timeout_sec}" -le 0 ]; then
    timeout_sec=1
  fi

  case "${interval_sec}" in
    ''|*[!0-9]*)
      interval_sec=1
      ;;
  esac
  if [ "${interval_sec}" -le 0 ]; then
    interval_sec=1
  fi

  max_attempts=$((timeout_sec / interval_sec))
  if [ "${max_attempts}" -le 0 ]; then
    max_attempts=1
  fi
  attempt=1

  while [ "${attempt}" -le "${max_attempts}" ]; do
    if bench_selector_ready_once; then
      return 0
    fi
    if [ "${attempt}" -lt "${max_attempts}" ]; then
      sleep "${interval_sec}"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

switch_proxy_to_bench_with_retry() {
  max_attempts="$1"
  sleep_sec="$2"
  attempt=1
  proxy_switch_payload="$(jq -cn --arg name "BENCH" '{name:$name}')"

  while [ "${attempt}" -le "${max_attempts}" ]; do
    if bench_selector_ready_once; then
      if api_call PUT "/proxies/PROXY" "${proxy_switch_payload}" > /dev/null 2>&1; then
        proxy_switched_to_bench=1
        bench_selector_last_error=""
        return 0
      fi
      bench_selector_last_error="switch_failed"
    fi

    if [ "${attempt}" -lt "${max_attempts}" ]; then
      sleep "${sleep_sec}"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

run_with_timeout() {
  timeout_sec="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_sec}" "$@"
    return $?
  fi

  "$@" &
  command_pid=$!

  (
    sleep "${timeout_sec}"
    kill -TERM "${command_pid}" >/dev/null 2>&1 || exit 0
    sleep 2
    kill -KILL "${command_pid}" >/dev/null 2>&1 || exit 0
  ) &
  watchdog_pid=$!

  if wait "${command_pid}"; then
    command_rc=0
  else
    command_rc=$?
  fi

  kill "${watchdog_pid}" >/dev/null 2>&1 || true
  wait "${watchdog_pid}" >/dev/null 2>&1 || true

  case "${command_rc}" in
    137|143)
      return 124
      ;;
  esac

  return "${command_rc}"
}

run_bench_docker() {
  run_with_timeout "${THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC}" "$@"
}

cleanup_isolated_runtime() {
  if [ -z "${bench_container_name}" ]; then
    return 0
  fi
  run_bench_docker docker rm -fv "${bench_container_name}" >/dev/null 2>&1 || true
  bench_container_name=""
}

start_isolated_runtime() {
  if ! command -v docker >/dev/null 2>&1; then
    throughput_reason="bench_runtime_create_failed"
    log "Docker CLI is unavailable in subscription-sync runtime."
    return 1
  fi

  if ! resolve_bench_ports; then
    return 1
  fi

  cleanup_orphan_bench_containers

  if [ "${bench_proxy_port}" -eq "${bench_api_port}" ]; then
    throughput_reason="bench_runtime_port_conflict"
    log "Bench proxy/api ports must differ (port=${bench_proxy_port})."
    return 1
  fi

  cp "${INPUT_FILE}" "${BENCH_PROVIDER_FILE}" || {
    throughput_reason="bench_runtime_cp_candidate_failed"
    log "Failed to prepare bench provider file from ${INPUT_FILE}."
    return 1
  }

  cat > "${BENCH_CONFIG_FILE}" <<EOF
mixed-port: ${bench_proxy_port}
allow-lan: false
mode: rule
log-level: error
external-controller: 127.0.0.1:${bench_api_port}
secret: "${THROUGHPUT_BENCH_API_SECRET}"
proxy-providers:
  test:
    type: file
    path: ./candidate.txt
proxy-groups:
  - name: AUTO_FAILSAFE
    type: fallback
    use:
      - test
    url: https://www.gstatic.com/generate_204
    interval: 600
  - name: BENCH
    type: select
    use:
      - test
  - name: PROXY
    type: select
    proxies:
      - AUTO_FAILSAFE
      - BENCH
      - DIRECT
rules:
  - MATCH,PROXY
EOF

  bench_container_name="mihomo-throughput-$$-$(date +%s)"
  if ! create_output="$(run_bench_docker docker create --name "${bench_container_name}" \
    --network host \
    "${MIHOMO_IMAGE}" \
    -d /root/.config/mihomo \
    -f /root/.config/mihomo/bench-config.yaml 2>&1)"; then
    throughput_reason="bench_runtime_create_failed"
    log "Bench docker create failed: $(error_summary "${create_output}")"
    cleanup_isolated_runtime
    return 1
  fi

  if ! cp_candidate_output="$(run_bench_docker docker cp "${BENCH_PROVIDER_FILE}" "${bench_container_name}:/root/.config/mihomo/candidate.txt" 2>&1)"; then
    throughput_reason="bench_runtime_cp_candidate_failed"
    log "Bench docker cp candidate failed: $(error_summary "${cp_candidate_output}")"
    cleanup_isolated_runtime
    return 1
  fi

  if ! cp_config_output="$(run_bench_docker docker cp "${BENCH_CONFIG_FILE}" "${bench_container_name}:/root/.config/mihomo/bench-config.yaml" 2>&1)"; then
    throughput_reason="bench_runtime_cp_config_failed"
    log "Bench docker cp config failed: $(error_summary "${cp_config_output}")"
    cleanup_isolated_runtime
    return 1
  fi

  if ! start_output="$(run_bench_docker docker start "${bench_container_name}" 2>&1)"; then
    throughput_reason="bench_runtime_start_failed"
    log "Bench docker start failed: $(error_summary "${start_output}")"
    cleanup_isolated_runtime
    return 1
  fi
  setup_api_context "http://127.0.0.1:${bench_api_port}" "${THROUGHPUT_BENCH_API_SECRET}"

  api_wait_attempt=1
  while [ "${api_wait_attempt}" -le 20 ]; do
    if api_call GET "/version" >/dev/null 2>&1; then
      PROXY_PORT="${bench_proxy_port}"
      PROXY_AUTH=""
      return 0
    fi
    sleep 1
    api_wait_attempt=$((api_wait_attempt + 1))
  done

  throughput_reason="bench_runtime_api_timeout"
  log "Bench runtime API did not become ready on 127.0.0.1:${bench_api_port} within timeout."
  cleanup_isolated_runtime
  return 1
}

sanitize_restore_target() {
  candidate="$1"

  case "${candidate}" in
    ''|BENCH|DIRECT)
      printf 'AUTO_FAILSAFE\n'
      return 0
      ;;
  esac

  if [ ! -s "${PROXY_ALL_FILE}" ]; then
    printf 'AUTO_FAILSAFE\n'
    return 0
  fi

  if grep -Fxq "${candidate}" "${PROXY_ALL_FILE}" 2>/dev/null; then
    printf '%s\n' "${candidate}"
  else
    printf 'AUTO_FAILSAFE\n'
  fi
}

restore_proxy_group() {
  if [ "${proxy_switched_to_bench}" -ne 1 ]; then
    return 0
  fi

  escaped_proxy="$(printf '%s' "${restore_target}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  restore_payload="$(printf '{"name":"%s"}' "${escaped_proxy}")"
  api_call PUT "/proxies/PROXY" "${restore_payload}" > /dev/null 2>&1 || true
  proxy_switched_to_bench=0
}

cleanup_rank() {
  if [ "${cleanup_done}" -eq 1 ]; then
    return 0
  fi
  cleanup_done=1
  restore_proxy_group
  cleanup_isolated_runtime
  rm -rf "${TMP_DIR}"
}

on_signal() {
  cleanup_rank
  exit 130
}

trap cleanup_rank EXIT
trap on_signal INT TERM

setup_api_context "http://${API_BIND}" "${API_SECRET}"

if ! api_call GET "/version" > /dev/null 2>&1; then
  throughput_reason="api_unreachable"
  print_metrics
  exit 0
fi

api_call PUT "/providers/proxies/main-subscription-ranked/healthcheck" > /dev/null 2>&1 || true
sleep 2

PROVIDERS_JSON="${TMP_DIR}/providers.json"
if ! api_call GET "/providers/proxies" > "${PROVIDERS_JSON}" 2>/dev/null; then
  throughput_reason="providers_unavailable"
  print_metrics
  exit 0
fi

CANDIDATES_FILE="${TMP_DIR}/candidates.txt"
jq -r --arg provider "main-subscription-ranked" --argjson top "${THROUGHPUT_TOP_N}" '
  .providers[$provider].proxies // []
  | map(select(.name != "DIRECT" and .name != "REJECT"))
  | map({name: .name, delay: ((.history // []) | map(.delay) | map(select(type=="number" and . > 0)) | min // 999999)})
  | sort_by(.delay)
  | .[:$top]
  | .[].name
' "${PROVIDERS_JSON}" > "${CANDIDATES_FILE}" || true

if [ ! -s "${CANDIDATES_FILE}" ]; then
  throughput_reason="no_candidates"
  print_metrics
  exit 0
fi

if [ "${THROUGHPUT_ISOLATED}" = "true" ]; then
  if ! start_isolated_runtime; then
    print_metrics
    exit 0
  fi
fi

CURRENT_PROXY_FILE="${TMP_DIR}/current_proxy.txt"
if api_call GET "/proxies/PROXY" > "${PROXY_STATE_FILE}" 2>/dev/null; then
  jq -r '.now // "AUTO_FAILSAFE"' "${PROXY_STATE_FILE}" > "${CURRENT_PROXY_FILE}" 2>/dev/null || echo "AUTO_FAILSAFE" > "${CURRENT_PROXY_FILE}"
  jq -r '.all[]?' "${PROXY_STATE_FILE}" > "${PROXY_ALL_FILE}" 2>/dev/null || : > "${PROXY_ALL_FILE}"
else
  echo "AUTO_FAILSAFE" > "${CURRENT_PROXY_FILE}"
  : > "${PROXY_ALL_FILE}"
fi
current_proxy="$(cat "${CURRENT_PROXY_FILE}")"
restore_target="$(sanitize_restore_target "${current_proxy}")"

if [ "${current_proxy}" = "BENCH" ]; then
  heal_payload="$(jq -cn --arg name "AUTO_FAILSAFE" '{name:$name}')"
  if api_call PUT "/proxies/PROXY" "${heal_payload}" > /dev/null 2>&1; then
    current_proxy="AUTO_FAILSAFE"
    restore_target="AUTO_FAILSAFE"
  fi
fi

if ! wait_for_bench_selector_ready "${THROUGHPUT_BENCH_DOCKER_TIMEOUT_SEC}" 1; then
  log "PROXY selector is not ready for BENCH (last_error=${bench_selector_last_error})"
  throughput_reason="bench_unavailable"
  print_metrics
  exit 0
fi

if ! switch_proxy_to_bench_with_retry 8 1; then
  log "Failed to switch PROXY to BENCH after retries (last_error=${bench_selector_last_error})"
  throughput_reason="bench_unavailable"
  print_metrics
  exit 0
fi

SCORES_FILE="${TMP_DIR}/scores.tsv"
: > "${SCORES_FILE}"

while IFS= read -r candidate; do
  [ -n "${candidate}" ] || continue
  throughput_tested=$((throughput_tested + 1))

  bench_payload="$(jq -cn --arg name "${candidate}" '{name:$name}')"
  if ! api_call PUT "/proxies/BENCH" "${bench_payload}" > /dev/null 2>&1; then
    throughput_failed=$((throughput_failed + 1))
    continue
  fi

  : > "${CANDIDATE_SPEEDS_FILE}"
  sample_index=1
  while [ "${sample_index}" -le "${THROUGHPUT_SAMPLES}" ]; do
    if [ -n "${PROXY_AUTH}" ]; then
      speed_raw="$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --silent --show-error \
        --proxy "http://127.0.0.1:${PROXY_PORT}" \
        --proxy-user "${PROXY_AUTH}" \
        --max-time "${THROUGHPUT_TIMEOUT_SEC}" \
        --connect-timeout 5 \
        --location \
        --output /dev/null \
        --write-out '%{speed_download}' \
        "${THROUGHPUT_TEST_URL}" 2>/dev/null || true)"
    else
      speed_raw="$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl --silent --show-error \
        --proxy "http://127.0.0.1:${PROXY_PORT}" \
        --max-time "${THROUGHPUT_TIMEOUT_SEC}" \
        --connect-timeout 5 \
        --location \
        --output /dev/null \
        --write-out '%{speed_download}' \
        "${THROUGHPUT_TEST_URL}" 2>/dev/null || true)"
    fi

    if printf '%s' "${speed_raw}" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
      speed_bps="$(awk -v s="${speed_raw}" 'BEGIN {printf "%.0f\n", s}')"
      if [ "${speed_bps}" -ge "${MIN_BPS}" ]; then
        printf '%s\n' "${speed_bps}" >> "${CANDIDATE_SPEEDS_FILE}"
      fi
    fi

    sample_index=$((sample_index + 1))
  done

  candidate_successes="$(wc -l < "${CANDIDATE_SPEEDS_FILE}" | tr -d ' ')"
  if [ "${candidate_successes}" -lt "${THROUGHPUT_REQUIRED_SUCCESSES}" ]; then
    throughput_failed=$((throughput_failed + 1))
    continue
  fi

  candidate_score="$(sort -n "${CANDIDATE_SPEEDS_FILE}" | awk '
  {
    vals[++n] = $1
  }
  END {
    if (n == 0) {
      print 0
      exit
    }
    if ((n % 2) == 1) {
      idx = (n + 1) / 2
      print vals[idx]
      exit
    }
    idx = n / 2
    print int((vals[idx] + vals[idx + 1]) / 2)
  }'
  )"

  case "${candidate_score}" in
    ''|*[!0-9]*)
      throughput_failed=$((throughput_failed + 1))
      continue
      ;;
  esac

  if [ "${candidate_score}" -ge "${MIN_BPS}" ]; then
    printf '%s\t%s\n' "${candidate_score}" "${candidate}" >> "${SCORES_FILE}"
    throughput_ranked=$((throughput_ranked + 1))
  else
    throughput_failed=$((throughput_failed + 1))
  fi
done < "${CANDIDATES_FILE}"

restore_proxy_group

if [ "${throughput_ranked}" -le 0 ] || [ ! -s "${SCORES_FILE}" ]; then
  throughput_reason="no_valid_speed"
  print_metrics
  exit 0
fi

SORTED_NAMES_FILE="${TMP_DIR}/sorted-names.txt"
sort -t "$(printf '\t')" -k1,1nr "${SCORES_FILE}" | cut -f2- > "${SORTED_NAMES_FILE}"

RANKED_TMP="${TMP_DIR}/ranked.out"
awk '
function urldecode(str,    out,i,c,hx) {
  out = ""
  i = 1
  while (i <= length(str)) {
    c = substr(str, i, 1)
    if (c == "%" && i + 2 <= length(str)) {
      hx = substr(str, i + 1, 2)
      if (hx ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
        out = out sprintf("%c", strtonum("0x" hx))
        i += 3
        continue
      }
    }
    if (c == "+") {
      c = " "
    }
    out = out c
    i++
  }
  return out
}
FNR == NR {
  order[++m] = $0
  next
}
{
  lines[++n] = $0
  hash = index($0, "#")
  if (hash > 0) {
    fragment = substr($0, hash + 1)
  } else {
    fragment = $0
  }
  names[n] = urldecode(fragment)
}
END {
  for (j = 1; j <= m; j++) {
    target = order[j]
    for (i = 1; i <= n; i++) {
      if (!used[i] && names[i] == target) {
        print lines[i]
        used[i] = 1
        break
      }
    }
  }
  for (i = 1; i <= n; i++) {
    if (!used[i]) {
      print lines[i]
    }
  }
}
' "${SORTED_NAMES_FILE}" "${INPUT_FILE}" > "${RANKED_TMP}"

if [ -s "${RANKED_TMP}" ]; then
  replace_file_from_source "${RANKED_TMP}" "${OUTPUT_FILE}" 2>/dev/null || true
  throughput_reason="ok"
else
  throughput_reason="rank_output_empty"
fi

print_metrics
