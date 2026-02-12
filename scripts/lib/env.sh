#!/usr/bin/env sh

trim_ws() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

strip_wrapping_quotes() {
  value="$1"
  case "${value}" in
    \"*\")
      if [ "${#value}" -ge 2 ]; then
        value="${value#\"}"
        value="${value%\"}"
      fi
      ;;
    \'*\')
      if [ "${#value}" -ge 2 ]; then
        value="${value#\'}"
        value="${value%\'}"
      fi
      ;;
  esac
  printf '%s' "${value}"
}

load_env_file() {
  env_file="$1"
  if [ ! -f "${env_file}" ]; then
    echo "Missing ${env_file}." >&2
    return 1
  fi

  while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
    line="$(trim_ws "${raw_line}")"
    if [ -z "${line}" ]; then
      continue
    fi

    case "${line}" in
      \#*)
        continue
        ;;
      export[[:space:]]*)
        line="$(trim_ws "${line#export}")"
        ;;
    esac

    case "${line}" in
      *=*)
        ;;
      *)
        continue
        ;;
    esac

    key="$(trim_ws "${line%%=*}")"
    value="$(trim_ws "${line#*=}")"

    case "${key}" in
      ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
        echo "Invalid variable name in ${env_file}: ${key}" >&2
        return 1
        ;;
    esac

    value="$(strip_wrapping_quotes "${value}")"
    export "${key}=${value}"
  done < "${env_file}"

  return 0
}

require_env_vars() {
  missing=0
  for name in "$@"; do
    case "${name}" in
      ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
        echo "Invalid variable name: ${name}" >&2
        return 1
        ;;
    esac

    value="$(printenv "${name}" 2>/dev/null || true)"
    if [ -z "${value}" ]; then
      echo "Required variable ${name} is empty." >&2
      missing=1
    fi
  done

  if [ "${missing}" -ne 0 ]; then
    return 1
  fi
  return 0
}
