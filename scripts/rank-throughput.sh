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

print_metrics() {
  echo "THROUGHPUT_TESTED=${throughput_tested}"
  echo "THROUGHPUT_RANKED=${throughput_ranked}"
  echo "THROUGHPUT_FAILED=${throughput_failed}"
  echo "THROUGHPUT_REASON=${throughput_reason}"
  echo "THROUGHPUT_TIMESTAMP=${throughput_timestamp}"
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
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_AUTH="${PROXY_AUTH:-}"
API_BIND="${API_BIND:-127.0.0.1:9090}"
API_SECRET="${API_SECRET:-}"

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

MIN_BPS=$((THROUGHPUT_MIN_KBPS * 1024))
TMP_DIR="$(mktemp -d "/tmp/mihomo-rank.XXXXXX" 2>/dev/null || mktemp -d "${ROOT_DIR}/runtime/rank.XXXXXX")"
PROXY_STATE_FILE="${TMP_DIR}/proxy-state.json"
PROXY_ALL_FILE="${TMP_DIR}/proxy-all.txt"
CANDIDATE_SPEEDS_FILE="${TMP_DIR}/candidate-speeds.txt"
current_proxy="AUTO_FAILSAFE"
restore_target="AUTO_FAILSAFE"
proxy_switched_to_bench=0
cleanup_done=0

api_base="http://${API_BIND}"
auth_header=""
if [ -n "${API_SECRET}" ]; then
  auth_header="Authorization: Bearer ${API_SECRET}"
fi

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
  rm -rf "${TMP_DIR}"
}

on_signal() {
  cleanup_rank
  exit 130
}

trap cleanup_rank EXIT
trap on_signal INT TERM

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

proxy_switch_payload="$(jq -cn --arg name "BENCH" '{name:$name}')"
if ! api_call PUT "/proxies/PROXY" "${proxy_switch_payload}" > /dev/null 2>&1; then
  throughput_reason="bench_unavailable"
  print_metrics
  exit 0
fi
proxy_switched_to_bench=1

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
