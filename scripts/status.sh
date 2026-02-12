#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATUS_FILE="${ROOT_DIR}/runtime/status.json"
METRICS_FILE="${ROOT_DIR}/runtime/metrics.json"

if [ ! -f "${STATUS_FILE}" ]; then
  echo "No status yet. Run ./scripts/sync-subscription.sh first."
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  status_line="$(jq -r '"status=\(.status) mode=\(.mode) sources=\(.source_ok // 0)/\(.source_total // 0) raw=\(.raw_count) filtered=\(.filtered_count) excluded_by_country=\(.excluded_by_country // 0) valid=\(.valid_count) dropped=\(.dropped_count) throughput=\(.throughput_ranked // 0)/\(.throughput_tested // 0) throughput_failed=\(.throughput_failed // 0) throughput_reason=\(.throughput_reason // "n/a") reason=\(.reason) fetched_at=\(.last_fetch)"' "${STATUS_FILE}")"
  if [ -f "${METRICS_FILE}" ]; then
    metrics_line="$(jq -r '"worker_status=\(.status // "n/a") consecutive_failures=\(.consecutive_failures // 0) worker_reason=\(.reason // "n/a") worker_updated_at=\(.updated_at // "n/a")"' "${METRICS_FILE}" 2>/dev/null || true)"
    if [ -n "${metrics_line}" ]; then
      echo "${status_line} ${metrics_line}"
      exit 0
    fi
  fi
  echo "${status_line}"
else
  cat "${STATUS_FILE}"
fi
