#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required." >&2
  exit 1
fi

patterns=(
  '/home/[A-Za-z0-9._-]+'
  '/Users/[A-Za-z0-9._-]+'
  'C:\\Users\\[A-Za-z0-9._-]+'
)

ignore_globs=(
  '--glob=!.git/*'
  '--glob=!runtime/*'
)

failed=0
for pattern in "${patterns[@]}"; do
  if rg -n --hidden "${ignore_globs[@]}" -e "${pattern}" .; then
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo
  echo "Portability check failed: found user-specific paths."
  exit 1
fi

echo "Portability check passed: no user-specific absolute paths found."
