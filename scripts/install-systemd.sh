#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_FILE="${ROOT_DIR}/systemd/mihomo-gateway.service.template"
UNIT_NAME="mihomo-gateway.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  echo "Missing template: ${TEMPLATE_FILE}" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required for systemd installation." >&2
  exit 1
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Run as root or install sudo to write ${UNIT_PATH}." >&2
    exit 1
  fi
fi

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

project_dir_escaped="$(escape_sed "${ROOT_DIR}")"
sed "s/__PROJECT_DIR__/${project_dir_escaped}/g" "${TEMPLATE_FILE}" > "${tmp_file}"

${SUDO} install -m 0644 "${tmp_file}" "${UNIT_PATH}"
${SUDO} systemctl daemon-reload
${SUDO} systemctl enable --now "${UNIT_NAME}"

echo "Installed and started ${UNIT_NAME}"
echo "Unit path: ${UNIT_PATH}"
echo "Project dir: ${ROOT_DIR}"
