#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
RUNTIME_DIR="${ROOT_DIR}/runtime"
PROVIDER_DIR="${RUNTIME_DIR}/proxy_providers"
PROVIDER_FILE="${PROVIDER_DIR}/main-subscription.yaml"
RANKED_PROVIDER_FILE="${PROVIDER_DIR}/main-subscription-ranked.yaml"
STATUS_FILE="${RUNTIME_DIR}/status.json"
LOCK_DIR="${RUNTIME_DIR}/.sync.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
TMP_DIR=""
LOCK_OWNED=0
LOCK_CLEANED=0
INTERRUPTING=0
INTERRUPT_GRACE_SEC=3

throughput_tested=0
throughput_ranked=0
throughput_failed=0
throughput_reason="not_run"
throughput_timestamp=""
validate_fail_reason="not_run"
owner_uid_gid="$(stat -c '%u:%g' "${ROOT_DIR}" 2>/dev/null || true)"

log() {
  printf '[subscription-sync] %s\n' "$*"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
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

count_provider_lines() {
  grep -Eci '^[[:space:]]*[a-zA-Z][a-zA-Z0-9+.-]*://' "${PROVIDER_FILE}" || true
}

write_status() {
  status="$1"
  reason="$2"
  raw_count="$3"
  filtered_count="$4"
  valid_count="$5"
  dropped_count="$6"
  mode="$7"
  degraded_mode="$8"
  source_urls="$9"
  source_total="${10}"
  source_ok="${11}"
  source_failed="${12}"
  excluded_by_country="${13}"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  reason_escaped="$(json_escape "${reason}")"
  mode_escaped="$(json_escape "${mode}")"
  source_urls_escaped="$(json_escape "${source_urls}")"
  degraded_escaped="$(json_escape "${degraded_mode}")"
  throughput_reason_escaped="$(json_escape "${throughput_reason}")"
  throughput_timestamp_escaped="$(json_escape "${throughput_timestamp}")"

  cat > "${STATUS_FILE}" <<EOF
{
  "last_fetch": "${timestamp}",
  "status": "${status}",
  "source_urls": "${source_urls_escaped}",
  "source_total": ${source_total},
  "source_ok": ${source_ok},
  "source_failed": ${source_failed},
  "mode": "${mode_escaped}",
  "raw_count": ${raw_count},
  "filtered_count": ${filtered_count},
  "excluded_by_country": ${excluded_by_country},
  "valid_count": ${valid_count},
  "dropped_count": ${dropped_count},
  "throughput_tested": ${throughput_tested},
  "throughput_ranked": ${throughput_ranked},
  "throughput_failed": ${throughput_failed},
  "throughput_timestamp": "${throughput_timestamp_escaped}",
  "throughput_reason": "${throughput_reason_escaped}",
  "reason": "${reason_escaped}",
  "degraded_mode": "${degraded_escaped}"
}
EOF

  fix_owner "${STATUS_FILE}"

  if [ "${SANITIZE_LOG_JSON}" = "true" ]; then
    cat "${STATUS_FILE}"
  fi
}

fetch_url() {
  url="$1"
  out_file="$2"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --connect-timeout 20 --max-time 120 "${url}" > "${out_file}"
    return $?
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "${out_file}" "${url}"
    return $?
  fi

  echo "Neither curl nor wget is available." >&2
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

cleanup_validate_container() {
  container_name="$1"
  run_with_timeout "${SANITIZE_VALIDATE_TIMEOUT_SEC}" docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

set_validate_fail_reason_by_rc() {
  rc="$1"
  if [ "${rc}" -eq 124 ]; then
    validate_fail_reason="timeout"
  else
    validate_fail_reason="docker_error"
  fi
}

run_validate_docker() {
  if run_with_timeout "${SANITIZE_VALIDATE_TIMEOUT_SEC}" "$@"; then
    return 0
  else
    command_rc="$?"
    set_validate_fail_reason_by_rc "${command_rc}"
    return 1
  fi
}

validate_provider_file() {
  provider_input="$1"
  validate_dir="$2"
  validate_log="$3"
  validate_container="mihomo-validate-$$-$(date +%s)"
  validate_fail_reason="unknown"

  : > "${validate_log}"

  cat > "${validate_dir}/validate-config.yaml" <<'EOF'
mixed-port: 7899
allow-lan: false
mode: rule
log-level: error
proxy-providers:
  test:
    type: file
    path: ./candidate.txt
proxy-groups:
  - name: P
    type: select
    use:
      - test
rules:
  - MATCH,P
EOF

  cleanup_validate_container "${validate_container}"

  if ! run_validate_docker docker create --name "${validate_container}" \
    docker.io/metacubex/mihomo:latest \
    -d /root/.config/mihomo \
    -f /root/.config/mihomo/validate-config.yaml >/dev/null; then
    cleanup_validate_container "${validate_container}"
    return 1
  fi

  if ! run_validate_docker docker cp "${provider_input}" "${validate_container}:/root/.config/mihomo/candidate.txt" >/dev/null; then
    cleanup_validate_container "${validate_container}"
    return 1
  fi

  if ! run_validate_docker docker cp "${validate_dir}/validate-config.yaml" "${validate_container}:/root/.config/mihomo/validate-config.yaml" >/dev/null; then
    cleanup_validate_container "${validate_container}"
    return 1
  fi

  if ! run_validate_docker docker start "${validate_container}" >/dev/null; then
    cleanup_validate_container "${validate_container}"
    return 1
  fi

  sleep 1

  if ! run_validate_docker docker logs "${validate_container}" > "${validate_log}" 2>&1; then
    cleanup_validate_container "${validate_container}"
    return 1
  fi

  cleanup_validate_container "${validate_container}"

  if grep -Eqi 'proxy [0-9]+ error:|pull error:' "${validate_log}"; then
    validate_fail_reason="proxy_error"
    return 1
  fi

  if grep -qi 'Initial configuration complete' "${validate_log}"; then
    validate_fail_reason="ok"
    return 0
  fi

  validate_fail_reason="unknown"
  return 1
}

run_throughput_ranking() {
  throughput_tested=0
  throughput_ranked=0
  throughput_failed=0
  throughput_reason="not_run"
  throughput_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  rank_script="${ROOT_DIR}/scripts/rank-throughput.sh"
  if [ ! -x "${rank_script}" ]; then
    throughput_reason="rank_script_missing"
    cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true
    return 0
  fi

  rank_output="$("${rank_script}" "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true)"
  if [ -z "${rank_output}" ]; then
    throughput_reason="rank_output_empty"
    cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true
    return 0
  fi

  while IFS='=' read -r key value; do
    case "${key}" in
      THROUGHPUT_TESTED) throughput_tested="${value}" ;;
      THROUGHPUT_RANKED) throughput_ranked="${value}" ;;
      THROUGHPUT_FAILED) throughput_failed="${value}" ;;
      THROUGHPUT_REASON) throughput_reason="${value}" ;;
      THROUGHPUT_TIMESTAMP) throughput_timestamp="${value}" ;;
    esac
  done <<EOF
${rank_output}
EOF

  if [ ! -s "${RANKED_PROVIDER_FILE}" ]; then
    cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true
    throughput_reason="rank_output_empty"
  fi
  fix_owner "${RANKED_PROVIDER_FILE}"
}

if [ ! -f "${ENV_FILE}" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and fill required values." >&2
  exit 1
fi

acquire_lock() {
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    printf '%s\n' "$$" > "${LOCK_PID_FILE}" 2>/dev/null || true
    LOCK_OWNED=1
    return 0
  fi

  lock_pid=""
  if [ -f "${LOCK_PID_FILE}" ]; then
    lock_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
  fi

  case "${lock_pid}" in
    ''|*[!0-9]*)
      lock_pid=""
      ;;
  esac

  if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" >/dev/null 2>&1; then
    log "Another sync is already running (pid=${lock_pid}); skipping this cycle."
    return 1
  fi

  if [ -n "${lock_pid}" ]; then
    log "Stale sync lock detected (pid=${lock_pid}), recovering lock."
  else
    log "Stale sync lock detected, recovering lock."
  fi

  if ! rm -rf "${LOCK_DIR}" 2>/dev/null; then
    log "Failed to remove stale lock at ${LOCK_DIR}; skipping this cycle."
    return 1
  fi

  if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    log "Another sync acquired lock while recovering; skipping this cycle."
    return 1
  fi

  printf '%s\n' "$$" > "${LOCK_PID_FILE}" 2>/dev/null || true
  LOCK_OWNED=1
  return 0
}

if ! acquire_lock; then
  exit 0
fi

list_child_pids() {
  if [ -r "/proc/$$/task/$$/children" ]; then
    child_line=""
    IFS= read -r child_line < "/proc/$$/task/$$/children" || true
    for pid in ${child_line}; do
      printf '%s\n' "${pid}"
    done
    return 0
  fi

  ps -o pid= --ppid "$$" 2>/dev/null | awk '{print $1}' || true
}

signal_children() {
  signal_name="$1"
  child_pids="$(list_child_pids)"
  if [ -z "${child_pids}" ]; then
    return 0
  fi
  # shellcheck disable=SC2086
  kill -"${signal_name}" ${child_pids} >/dev/null 2>&1 || true
}

wait_children_exit() {
  timeout_sec="$1"
  waited=0
  while [ "${waited}" -lt "${timeout_sec}" ]; do
    child_pids="$(list_child_pids)"
    if [ -z "${child_pids}" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

cleanup_lock() {
  if [ "${LOCK_CLEANED}" -eq 1 ]; then
    return 0
  fi
  LOCK_CLEANED=1

  if [ -n "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
    TMP_DIR=""
  fi

  if [ "${LOCK_OWNED}" -ne 1 ]; then
    return 0
  fi

  lock_pid=""
  if [ -f "${LOCK_PID_FILE}" ]; then
    lock_pid="$(cat "${LOCK_PID_FILE}" 2>/dev/null || true)"
  fi

  if [ -n "${lock_pid}" ] && [ "${lock_pid}" != "$$" ]; then
    log "Lock ownership changed to pid=${lock_pid}; keeping ${LOCK_DIR}."
    return 0
  fi

  rm -f "${LOCK_PID_FILE}" >/dev/null 2>&1 || true
  rm -rf "${LOCK_DIR}" >/dev/null 2>&1 || true
}

on_interrupt() {
  signal_name="$1"
  if [ "${INTERRUPTING}" -eq 1 ]; then
    exit 130
  fi
  INTERRUPTING=1
  log "Received ${signal_name}; terminating child processes and releasing lock."

  signal_children TERM
  if ! wait_children_exit "${INTERRUPT_GRACE_SEC}"; then
    signal_children KILL
  fi

  cleanup_lock
  exit 130
}

trap cleanup_lock EXIT
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM

# shellcheck disable=SC1090
set -a
. "${ENV_FILE}"
set +a

SUBSCRIPTION_URLS="${SUBSCRIPTION_URLS:-}"
SUBSCRIPTION_URL="${SUBSCRIPTION_URL:-}"
EXCLUDE_COUNTRIES="${EXCLUDE_COUNTRIES:-}"
SANITIZE_INTERVAL="${SANITIZE_INTERVAL:-300}"
MIN_VALID_PROXIES="${MIN_VALID_PROXIES:-1}"
SANITIZE_ALLOW_PROTOCOLS="${SANITIZE_ALLOW_PROTOCOLS:-vless,trojan,ss,vmess}"
SANITIZE_LOG_JSON="${SANITIZE_LOG_JSON:-true}"
SANITIZE_VALIDATE_TIMEOUT_SEC="${SANITIZE_VALIDATE_TIMEOUT_SEC:-10}"
SANITIZE_VALIDATE_MAX_ITERATIONS="${SANITIZE_VALIDATE_MAX_ITERATIONS:-80}"

case "${SANITIZE_VALIDATE_TIMEOUT_SEC}" in
  ''|*[!0-9]*)
    SANITIZE_VALIDATE_TIMEOUT_SEC=10
    ;;
esac
if [ "${SANITIZE_VALIDATE_TIMEOUT_SEC}" -le 0 ]; then
  SANITIZE_VALIDATE_TIMEOUT_SEC=10
fi

case "${SANITIZE_VALIDATE_MAX_ITERATIONS}" in
  ''|*[!0-9]*)
    SANITIZE_VALIDATE_MAX_ITERATIONS=80
    ;;
esac
if [ "${SANITIZE_VALIDATE_MAX_ITERATIONS}" -le 0 ]; then
  SANITIZE_VALIDATE_MAX_ITERATIONS=80
fi

mkdir -p "${PROVIDER_DIR}"
if [ ! -f "${PROVIDER_FILE}" ]; then
  : > "${PROVIDER_FILE}"
fi
if [ ! -f "${RANKED_PROVIDER_FILE}" ]; then
  cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || : > "${RANKED_PROVIDER_FILE}"
fi
fix_owner "${PROVIDER_FILE}"
fix_owner "${RANKED_PROVIDER_FILE}"

TMP_DIR="$(mktemp -d "${RUNTIME_DIR}/sync.XXXXXX")"

SOURCE_LIST_FILE="${TMP_DIR}/source-urls.txt"
MERGED_URI_FILE="${TMP_DIR}/merged-uris.txt"
FILTERED_FILE="${TMP_DIR}/filtered.txt"
COUNTRY_FILTERED_FILE="${TMP_DIR}/country-filtered.txt"
WORKING_FILE="${TMP_DIR}/working.txt"
VALIDATE_LOG="${TMP_DIR}/validate.log"
COUNTRY_EXCLUDED_COUNT_FILE="${TMP_DIR}/country-excluded-count.txt"
SINGLE_YAML_FILE="${TMP_DIR}/single-source.yaml"

: > "${SOURCE_LIST_FILE}"
: > "${MERGED_URI_FILE}"

if [ -n "${SUBSCRIPTION_URLS}" ]; then
  printf '%s' "${SUBSCRIPTION_URLS}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' >> "${SOURCE_LIST_FILE}"
fi

if [ ! -s "${SOURCE_LIST_FILE}" ] && [ -n "${SUBSCRIPTION_URL}" ]; then
  printf '%s\n' "${SUBSCRIPTION_URL}" >> "${SOURCE_LIST_FILE}"
fi

if [ -s "${SOURCE_LIST_FILE}" ]; then
  awk '!seen[$0]++' "${SOURCE_LIST_FILE}" > "${TMP_DIR}/source-urls.unique"
  mv "${TMP_DIR}/source-urls.unique" "${SOURCE_LIST_FILE}"
fi

source_total="$(wc -l < "${SOURCE_LIST_FILE}" | tr -d ' ')"
source_ok=0
source_failed=0
raw_count=0
filtered_count=0
excluded_by_country=0
valid_count=0
dropped_count=0
mode="uri"

source_urls_joined="$(awk 'BEGIN{first=1} {if(!first) printf ","; printf "%s",$0; first=0} END{print ""}' "${SOURCE_LIST_FILE}")"

if [ "${source_total}" -eq 0 ]; then
  existing_count="$(count_provider_lines)"
  write_status "degraded_direct" "no_sources" 0 0 "${existing_count}" 0 "unknown" "direct" "" 0 0 0 0
  log "No subscription URLs configured. Set SUBSCRIPTION_URLS or SUBSCRIPTION_URL."
  exit 0
fi

single_yaml_mode=""
index=0

while IFS= read -r source_url; do
  index=$((index + 1))
  src_raw="${TMP_DIR}/source-${index}.raw"
  src_normalized="${TMP_DIR}/source-${index}.normalized"
  src_decoded="${TMP_DIR}/source-${index}.decoded"
  src_input="${TMP_DIR}/source-${index}.input"
  src_mode="uri"

  if ! fetch_url "${source_url}" "${src_raw}"; then
    source_failed=$((source_failed + 1))
    log "Source fetch failed: ${source_url}"
    continue
  fi

  tr -d '\r' < "${src_raw}" | sed 's/&amp;/\&/g' > "${src_normalized}"
  cp "${src_normalized}" "${src_input}"

  if grep -Eq '^[[:space:]]*proxies:' "${src_normalized}"; then
    src_mode="yaml"
  elif ! grep -Eq '://' "${src_normalized}"; then
    if base64 -d "${src_normalized}" > "${src_decoded}" 2>/dev/null; then
      tr -d '\r' < "${src_decoded}" | sed 's/&amp;/\&/g' > "${src_input}"
      if grep -Eq '^[[:space:]]*proxies:' "${src_input}"; then
        src_mode="yaml-base64"
      elif grep -Eq '://' "${src_input}"; then
        src_mode="uri-base64"
      else
        src_mode="unknown-base64"
      fi
    else
      src_mode="unknown"
    fi
  fi

  if [ "${src_mode}" = "yaml" ] || [ "${src_mode}" = "yaml-base64" ]; then
    if [ "${source_total}" -eq 1 ]; then
      cp "${src_input}" "${SINGLE_YAML_FILE}"
      single_yaml_mode="${src_mode}"
      source_ok=$((source_ok + 1))
      mode="${src_mode}"
    else
      source_failed=$((source_failed + 1))
      log "Skipping YAML source in multi-source mode: ${source_url}"
    fi
    continue
  fi

  if [ "${src_mode}" = "uri" ] || [ "${src_mode}" = "uri-base64" ]; then
    grep -E '^[[:space:]]*[a-zA-Z][a-zA-Z0-9+.-]*://' "${src_input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' >> "${MERGED_URI_FILE}" || true
    src_uri_count="$(grep -Eci '^[[:space:]]*[a-zA-Z][a-zA-Z0-9+.-]*://' "${src_input}" || true)"
    if [ "${src_uri_count}" -gt 0 ]; then
      source_ok=$((source_ok + 1))
      if [ "${source_total}" -gt 1 ]; then
        mode="multi-uri"
      else
        mode="${src_mode}"
      fi
    else
      source_failed=$((source_failed + 1))
      log "Source had no URI lines: ${source_url}"
    fi
    continue
  fi

  source_failed=$((source_failed + 1))
  log "Unsupported source format: ${source_url}"
done < "${SOURCE_LIST_FILE}"

if [ "${source_ok}" -eq 0 ]; then
  existing_count="$(count_provider_lines)"
  write_status "degraded_direct" "all_sources_failed" 0 0 "${existing_count}" 0 "unknown" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" 0
  log "All sources failed, keeping previous provider file."
  exit 0
fi

if [ -n "${single_yaml_mode}" ] && [ "${source_total}" -eq 1 ]; then
  raw_count="$(grep -Eci '^[[:space:]]*[a-zA-Z][a-zA-Z0-9+.-]*://' "${SINGLE_YAML_FILE}" || true)"
  filtered_count="${raw_count}"
  excluded_by_country=0
  valid_count="${raw_count}"
  dropped_count=0

  if validate_provider_file "${SINGLE_YAML_FILE}" "${TMP_DIR}" "${VALIDATE_LOG}"; then
    cp "${SINGLE_YAML_FILE}" "${TMP_DIR}/provider.new"
    mv "${TMP_DIR}/provider.new" "${PROVIDER_FILE}"
    fix_owner "${PROVIDER_FILE}"
    cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true
    fix_owner "${RANKED_PROVIDER_FILE}"
    run_throughput_ranking
    write_status "healthy" "ok" "${raw_count}" "${filtered_count}" "${valid_count}" "${dropped_count}" "${single_yaml_mode}" "" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" "${excluded_by_country}"
    log "Single-source YAML subscription synced (${single_yaml_mode})."
  else
    existing_count="$(count_provider_lines)"
    degraded_reason="yaml_validation_error"
    if [ "${validate_fail_reason}" = "timeout" ]; then
      degraded_reason="validation_timeout"
    fi
    write_status "degraded_direct" "${degraded_reason}" "${raw_count}" "${filtered_count}" "${existing_count}" "${dropped_count}" "${single_yaml_mode}" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" "${excluded_by_country}"
    log "Single-source YAML validation failed, keeping previous provider file."
  fi
  exit 0
fi

raw_count="$(wc -l < "${MERGED_URI_FILE}" | tr -d ' ')"
if [ "${raw_count}" -eq 0 ]; then
  existing_count="$(count_provider_lines)"
  write_status "degraded_direct" "no_uri_lines" 0 0 "${existing_count}" 0 "${mode}" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" 0
  log "No URI proxies after source merge, keeping previous provider file."
  exit 0
fi

allow_pattern="$(printf '%s' "${SANITIZE_ALLOW_PROTOCOLS}" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | sed 's/,/|/g')"
if [ -z "${allow_pattern}" ]; then
  allow_pattern="vless|trojan|ss|vmess"
fi

awk -v "allow_re=^(${allow_pattern})://" '
{
  line = $0
  sub(/^[[:space:]]+/, "", line)
  sub(/[[:space:]]+$/, "", line)
  if (line == "" || line ~ /^#/) {
    next
  }
  lower = tolower(line)
  if (lower ~ allow_re) {
    print line
  }
}
' "${MERGED_URI_FILE}" | awk '!seen[$0]++' > "${FILTERED_FILE}"

filtered_count="$(wc -l < "${FILTERED_FILE}" | tr -d ' ')"
if [ "${filtered_count}" -eq 0 ]; then
  existing_count="$(count_provider_lines)"
  write_status "degraded_direct" "no_allowed_protocols" "${raw_count}" 0 "${existing_count}" "${raw_count}" "${mode}" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" 0
  log "No proxies left after protocol filter, keeping previous provider file."
  exit 0
fi

exclude_countries_upper="$(printf '%s' "${EXCLUDE_COUNTRIES}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
if [ -n "${exclude_countries_upper}" ]; then
  awk -v "exclude_csv=${exclude_countries_upper}" -v "excluded_count_file=${COUNTRY_EXCLUDED_COUNT_FILE}" '
function emoji_for_code(code) {
  if (code == "RU") return "🇷🇺";
  if (code == "BY") return "🇧🇾";
  if (code == "US") return "🇺🇸";
  if (code == "GB") return "🇬🇧";
  if (code == "DE") return "🇩🇪";
  if (code == "FR") return "🇫🇷";
  if (code == "NL") return "🇳🇱";
  if (code == "FI") return "🇫🇮";
  if (code == "SE") return "🇸🇪";
  if (code == "CA") return "🇨🇦";
  if (code == "LV") return "🇱🇻";
  if (code == "LT") return "🇱🇹";
  if (code == "PL") return "🇵🇱";
  if (code == "EE") return "🇪🇪";
  if (code == "ES") return "🇪🇸";
  if (code == "TR") return "🇹🇷";
  if (code == "CH") return "🇨🇭";
  if (code == "UA") return "🇺🇦";
  if (code == "CN") return "🇨🇳";
  if (code == "JP") return "🇯🇵";
  if (code == "KR") return "🇰🇷";
  if (code == "SG") return "🇸🇬";
  if (code == "IN") return "🇮🇳";
  if (code == "MY") return "🇲🇾";
  if (code == "HK") return "🇭🇰";
  if (code == "VN") return "🇻🇳";
  if (code == "SA") return "🇸🇦";
  return "";
}
function should_exclude(display_name, upper_name, code, token_re, flag) {
  for (code in exclude_codes) {
    token_re = "(^|[^A-Z])" code "([^A-Z]|$)"
    if (upper_name ~ token_re) {
      return 1
    }
    flag = emoji_for_code(code)
    if (flag != "" && index(display_name, flag) > 0) {
      return 1
    }
  }
  return 0
}
BEGIN {
  excluded_count = 0
  split(exclude_csv, parts, ",")
  for (i in parts) {
    code = parts[i]
    if (code != "") {
      exclude_codes[code] = 1
    }
  }
}
{
  line = $0
  display_name = line
  hash_index = index(line, "#")
  if (hash_index > 0) {
    display_name = substr(line, hash_index + 1)
  }
  gsub(/[[:space:]]+/, " ", display_name)
  sub(/^[[:space:]]+/, "", display_name)
  sub(/[[:space:]]+$/, "", display_name)
  upper_name = toupper(display_name)

  if (should_exclude(display_name, upper_name)) {
    excluded_count++
    next
  }

  print line
}
END {
  print excluded_count > excluded_count_file
}
' "${FILTERED_FILE}" > "${COUNTRY_FILTERED_FILE}"
  excluded_by_country="$(cat "${COUNTRY_EXCLUDED_COUNT_FILE}" 2>/dev/null || printf '0')"
else
  cp "${FILTERED_FILE}" "${COUNTRY_FILTERED_FILE}"
  excluded_by_country=0
fi

country_count="$(wc -l < "${COUNTRY_FILTERED_FILE}" | tr -d ' ')"
if [ "${country_count}" -eq 0 ]; then
  existing_count="$(count_provider_lines)"
  reason="all_excluded_by_country"
  if [ "${excluded_by_country}" -eq 0 ]; then
    reason="no_allowed_protocols"
  fi
  write_status "degraded_direct" "${reason}" "${raw_count}" "${filtered_count}" "${existing_count}" "${raw_count}" "${mode}" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" "${excluded_by_country}"
  log "No proxies left after country/protocol filters, keeping previous provider file."
  exit 0
fi

cp "${COUNTRY_FILTERED_FILE}" "${WORKING_FILE}"

validation_timeout_hit=0
validation_iteration_cap_hit=0
validation_iterations=0

while :; do
  validation_iterations=$((validation_iterations + 1))
  if [ "${validation_iterations}" -gt "${SANITIZE_VALIDATE_MAX_ITERATIONS}" ]; then
    validation_iteration_cap_hit=1
    log "Validation iteration limit reached (${SANITIZE_VALIDATE_MAX_ITERATIONS}), aborting sanitize loop."
    break
  fi

  if validate_provider_file "${WORKING_FILE}" "${TMP_DIR}" "${VALIDATE_LOG}"; then
    break
  fi

  if [ "${validate_fail_reason}" = "timeout" ]; then
    validation_timeout_hit=1
    log "Validation timed out after ${SANITIZE_VALIDATE_TIMEOUT_SEC}s, aborting sanitize loop."
    break
  fi

  bad_index="$(sed -n 's/.*proxy \([0-9][0-9]*\) error:.*/\1/p' "${VALIDATE_LOG}" | head -n 1)"
  if [ -z "${bad_index}" ]; then
    break
  fi

  total_lines="$(wc -l < "${WORKING_FILE}" | tr -d ' ')"
  case "${bad_index}" in
    ''|*[!0-9]*)
      break
      ;;
  esac

  if [ "${bad_index}" -gt "${total_lines}" ]; then
    break
  fi

  bad_line="${bad_index}"
  if [ "${bad_line}" -eq 0 ]; then
    bad_line=1
  fi

  sed "${bad_line}d" "${WORKING_FILE}" > "${TMP_DIR}/working.next"
  mv "${TMP_DIR}/working.next" "${WORKING_FILE}"

  total_lines="$(wc -l < "${WORKING_FILE}" | tr -d ' ')"
  if [ "${total_lines}" -le 0 ]; then
    break
  fi
done

valid_count="$(wc -l < "${WORKING_FILE}" | tr -d ' ')"
dropped_count=$((raw_count - valid_count))
if [ "${dropped_count}" -lt 0 ]; then
  dropped_count=0
fi

final_validation_ok=0
if [ "${validation_timeout_hit}" -eq 0 ] && [ "${validation_iteration_cap_hit}" -eq 0 ] && [ "${valid_count}" -ge "${MIN_VALID_PROXIES}" ]; then
  if validate_provider_file "${WORKING_FILE}" "${TMP_DIR}" "${VALIDATE_LOG}"; then
    final_validation_ok=1
  elif [ "${validate_fail_reason}" = "timeout" ]; then
    validation_timeout_hit=1
  fi
fi

if [ "${final_validation_ok}" -eq 1 ]; then
  cp "${WORKING_FILE}" "${TMP_DIR}/provider.new"
  mv "${TMP_DIR}/provider.new" "${PROVIDER_FILE}"
  fix_owner "${PROVIDER_FILE}"
  cp "${PROVIDER_FILE}" "${RANKED_PROVIDER_FILE}" 2>/dev/null || true
  fix_owner "${RANKED_PROVIDER_FILE}"
  run_throughput_ranking
  write_status "healthy" "ok" "${raw_count}" "${filtered_count}" "${valid_count}" "${dropped_count}" "${mode}" "" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" "${excluded_by_country}"
  log "Subscription synced: raw=${raw_count} filtered=${filtered_count} excluded_by_country=${excluded_by_country} valid=${valid_count} dropped=${dropped_count} throughput_ranked=${throughput_ranked} throughput_reason=${throughput_reason}."
else
  existing_count="$(count_provider_lines)"
  degraded_reason="validation_failed_or_not_enough_proxies"
  if [ "${validation_timeout_hit}" -eq 1 ]; then
    degraded_reason="validation_timeout"
  elif [ "${validation_iteration_cap_hit}" -eq 1 ]; then
    degraded_reason="validation_iteration_limit"
  fi
  write_status "degraded_direct" "${degraded_reason}" "${raw_count}" "${filtered_count}" "${existing_count}" "${dropped_count}" "${mode}" "direct" "${source_urls_joined}" "${source_total}" "${source_ok}" "${source_failed}" "${excluded_by_country}"
  log "Validation failed or too few valid proxies, keeping previous provider file."
fi
