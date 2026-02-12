#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/runtime"
MAX_AGE_HOURS=24
QUIET=0

usage() {
  echo "Usage: $0 [--hours N] [--quiet]" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --hours)
      shift
      if [[ -z "${1:-}" ]]; then
        usage
        exit 1
      fi
      MAX_AGE_HOURS="$1"
      ;;
    --quiet)
      QUIET=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

case "${MAX_AGE_HOURS}" in
  ''|*[!0-9]*)
    echo "Invalid --hours value: ${MAX_AGE_HOURS}" >&2
    exit 1
    ;;
esac

if [[ "${MAX_AGE_HOURS}" -lt 1 ]]; then
  echo "--hours must be >= 1" >&2
  exit 1
fi

if [[ ! -d "${RUNTIME_DIR}" ]]; then
  if [[ "${QUIET}" -ne 1 ]]; then
    echo "Runtime directory not found: ${RUNTIME_DIR}"
  fi
  exit 0
fi

max_age_minutes=$((MAX_AGE_HOURS * 60))
removed=0
failed=0
checked=0

shopt -s nullglob
for dir_path in "${RUNTIME_DIR}"/sync.* "${RUNTIME_DIR}"/rank.*; do
  [[ -d "${dir_path}" ]] || continue
  checked=$((checked + 1))

  if ! find "${dir_path}" -maxdepth 0 -type d -mmin +"${max_age_minutes}" | grep -q .; then
    continue
  fi

  if rm -rf "${dir_path}" >/dev/null 2>&1; then
    removed=$((removed + 1))
  else
    failed=$((failed + 1))
    if [[ "${QUIET}" -ne 1 ]]; then
      echo "Failed to remove stale runtime dir: ${dir_path}" >&2
    fi
  fi
done
shopt -u nullglob

if [[ "${QUIET}" -ne 1 ]]; then
  echo "Runtime cleanup: checked=${checked} removed=${removed} failed=${failed} max_age_hours=${MAX_AGE_HOURS}"
fi

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi
