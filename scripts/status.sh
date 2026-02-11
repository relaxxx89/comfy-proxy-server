#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATUS_FILE="${ROOT_DIR}/runtime/status.json"

if [ ! -f "${STATUS_FILE}" ]; then
  echo "No status yet. Run ./scripts/sync-subscription.sh first."
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  jq -r '"status=\(.status) mode=\(.mode) sources=\(.source_ok // 0)/\(.source_total // 0) raw=\(.raw_count) filtered=\(.filtered_count) excluded_by_country=\(.excluded_by_country // 0) valid=\(.valid_count) dropped=\(.dropped_count) throughput=\(.throughput_ranked // 0)/\(.throughput_tested // 0) throughput_failed=\(.throughput_failed // 0) throughput_reason=\(.throughput_reason // "n/a") reason=\(.reason) fetched_at=\(.last_fetch)"' "${STATUS_FILE}"
else
  cat "${STATUS_FILE}"
fi
