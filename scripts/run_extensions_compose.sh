#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FETCH_CHILDREN_SCRIPT="${SCRIPT_DIR}/fetch_children.sh"
COMPOSE_FILE="${LCE_DIR}/docker-compose.run.yml"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"

LOG_DIR="${WORK_DIR}/logs"
mkdir -p "${LOG_DIR}"

LCE_PORT="${LCE_PORT:-4000}"
ZEBRA_WEB_PORT="${ZEBRA_WEB_PORT:-18000}"
RFID_WEB_PORT="${RFID_WEB_PORT:-8787}"
LCE_WAIT_ATTEMPTS="${LCE_WAIT_ATTEMPTS:-120}"
LCE_WAIT_DELAY="${LCE_WAIT_DELAY:-0.5}"
LCE_FORCE_RESTART="${LCE_FORCE_RESTART:-1}"
LCE_AUTO_FETCH_CHILDREN="${LCE_AUTO_FETCH_CHILDREN:-1}"
LCE_DRY_RUN="${LCE_DRY_RUN:-0}"
LCE_DEV_IMAGE="${LCE_DEV_IMAGE:-lce-bridge-dev:elixir-1.16.2-dotnet-10.0}"
LCE_USE_PREBUILT_DEV_IMAGE="${LCE_USE_PREBUILT_DEV_IMAGE:-0}"
LCE_SIM_MODE="${LCE_SIM_MODE:-0}"
LCE_DOCKER_PRIVILEGED="${LCE_DOCKER_PRIVILEGED:-1}"
LCE_DOCKER_HOST_NETWORK="${LCE_DOCKER_HOST_NETWORK:-0}"
LCE_ZEBRA_TUI_NO_BUILD="${LCE_ZEBRA_TUI_NO_BUILD:-1}"
ZEBRA_AUTOPRINT_ENABLED="${ZEBRA_AUTOPRINT_ENABLED:-0}"
ZEBRA_FEED_AFTER_ENCODE="${ZEBRA_FEED_AFTER_ENCODE:-0}"
ZEBRA_PRINTER_SIMULATE="${ZEBRA_PRINTER_SIMULATE:-}"
TG_TOKEN="${TG_TOKEN:-}"

LCE_MIX_CACHE_DIR="${LCE_MIX_CACHE_DIR:-${WORK_DIR}/.cache/lce-mix}"
LCE_BUILD_CACHE_DIR="${LCE_BUILD_CACHE_DIR:-${WORK_DIR}/.cache/lce-build}"
LCE_DEPS_CACHE_DIR="${LCE_DEPS_CACHE_DIR:-${WORK_DIR}/.cache/lce-deps}"
LCE_PG_DATA_DIR="${LCE_PG_DATA_DIR:-${WORK_DIR}/.cache/lce-postgres-data}"
LCE_NUGET_CACHE_DIR="${LCE_NUGET_CACHE_DIR:-${WORK_DIR}/.cache/lce-nuget}"
LCE_CLOAK_KEY_FILE="${LCE_CLOAK_KEY_FILE:-${WORK_DIR}/.cache/lce-cloak.key}"

detect_zebra_dir() {
  local dir="${LCE_ZEBRA_HOST_DIR:-}"
  if [[ -n "${dir}" ]]; then
    printf '%s' "${dir}"
    return 0
  fi

  if [[ -d "${WORK_DIR}/zebra_v1" && -f "${WORK_DIR}/zebra_v1/run.sh" ]]; then
    dir="${WORK_DIR}/zebra_v1"
  elif [[ -d "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version" && -f "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version/run.sh" ]]; then
    dir="${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
  elif [[ -d "${LCE_DIR}/zebra_v1" && -f "${LCE_DIR}/zebra_v1/run.sh" ]]; then
    dir="${LCE_DIR}/zebra_v1"
  elif [[ -d "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version" && -f "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version/run.sh" ]]; then
    dir="${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version"
  else
    dir=""
  fi

  printf '%s' "${dir}"
}

detect_rfid_dir() {
  local dir="${LCE_RFID_HOST_DIR:-}"
  if [[ -n "${dir}" ]]; then
    printf '%s' "${dir}"
    return 0
  fi

  if [[ -d "${WORK_DIR}/rfid" && -f "${WORK_DIR}/rfid/start-web.sh" ]]; then
    dir="${WORK_DIR}/rfid"
  elif [[ -d "${WORK_DIR}/ERPNext_UHFReader288_integration" && -f "${WORK_DIR}/ERPNext_UHFReader288_integration/start-web.sh" ]]; then
    dir="${WORK_DIR}/ERPNext_UHFReader288_integration"
  elif [[ -d "${LCE_DIR}/rfid" && -f "${LCE_DIR}/rfid/start-web.sh" ]]; then
    dir="${LCE_DIR}/rfid"
  elif [[ -d "${LCE_DIR}/ERPNext_UHFReader288_integration" && -f "${LCE_DIR}/ERPNext_UHFReader288_integration/start-web.sh" ]]; then
    dir="${LCE_DIR}/ERPNext_UHFReader288_integration"
  else
    dir=""
  fi

  printf '%s' "${dir}"
}

trim_token() {
  local token="${1-}"
  token="${token//$'\r'/}"
  token="${token//$'\n'/}"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  printf '%s' "${token}"
}

valid_telegram_token() {
  local token
  token="$(trim_token "${1-}")"
  [[ "${token}" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]]
}

mask_token() {
  local token="$1"
  local len=${#token}
  if ((len <= 8)); then
    printf '%s***' "${token:0:2}"
  else
    printf '%s***%s' "${token:0:5}" "${token: -3}"
  fi
}

read_secret_with_mask() {
  local prompt="$1"
  local secret=""
  local char=""

  if [[ ! -t 0 ]]; then
    REPLY=""
    return 0
  fi

  printf "%s" "${prompt}"

  if ! stty -echo 2>/dev/null; then
    IFS= read -r secret
    printf "\n"
    REPLY="${secret}"
    return 0
  fi

  while IFS= read -r -n1 char; do
    if [[ -z "${char}" || "${char}" == $'\n' || "${char}" == $'\r' ]]; then
      break
    fi
    if [[ "${char}" == $'\177' || "${char}" == $'\b' ]]; then
      if [[ -n "${secret}" ]]; then
        secret="${secret%?}"
        printf "\b \b"
      fi
      continue
    fi
    secret+="${char}"
    printf "*"
  done
  stty echo 2>/dev/null || true
  printf "\n"
  REPLY="${secret}"
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    echo python3
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    echo python
    return 0
  fi
  return 1
}

ensure_cloak_key() {
  if [[ -n "${CLOAK_KEY:-}" ]]; then
    return 0
  fi

  local key=""
  if [[ -f "${LCE_CLOAK_KEY_FILE}" ]]; then
    key="$(cat "${LCE_CLOAK_KEY_FILE}" 2>/dev/null || true)"
    key="$(trim_token "${key}")"
  fi

  if [[ -z "${key}" ]]; then
    mkdir -p "$(dirname -- "${LCE_CLOAK_KEY_FILE}")"

    if command -v openssl >/dev/null 2>&1; then
      key="$(openssl rand -base64 32 | tr -d '\n\r')"
    else
      local py
      py="$(python_bin 2>/dev/null || true)"
      if [[ -n "${py}" ]]; then
        key="$("${py}" - <<'PY'
import os
import base64
print(base64.b64encode(os.urandom(32)).decode("ascii"))
PY
)"
      else
        key="$(head -c 32 /dev/urandom | base64 | tr -d '\n\r')"
      fi
    fi

    if [[ -z "${key}" ]]; then
      echo "ERROR: Failed to generate CLOAK_KEY" >&2
      exit 1
    fi

    ( umask 077 && printf '%s' "${key}" > "${LCE_CLOAK_KEY_FILE}" ) || true
    chmod 600 "${LCE_CLOAK_KEY_FILE}" >/dev/null 2>&1 || true
  fi

  export CLOAK_KEY="${key}"
}

wait_for_url() {
  local url="$1"
  local attempts="${2:-40}"
  local delay="${3:-0.25}"

  for _ in $(seq 1 "${attempts}"); do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "${url}" >/dev/null 2>&1 && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -qO /dev/null "${url}" >/dev/null 2>&1 && return 0
    fi
    sleep "${delay}"
  done

  return 1
}

wait_for_core_ready() {
  local attempts="${LCE_CORE_WAIT_ATTEMPTS:-240}"
  local delay="${LCE_CORE_WAIT_DELAY:-0.25}"
  local status_url="http://127.0.0.1:${LCE_PORT}/api/status"

  for _ in $(seq 1 "${attempts}"); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "${status_url}" 2>/dev/null | grep -q '"device_id":"CORE-'; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO- "${status_url}" 2>/dev/null | grep -q '"device_id":"CORE-'; then
        return 0
      fi
    fi
    sleep "${delay}"
  done

  return 1
}

post_config() {
  local telegram_token="$1"
  local zebra_url="$2"
  local rfid_url="$3"
  local target="${LCE_CHILDREN_TARGET:-zebra}"
  local target_lc="${target,,}"

  local telegram_token_val=""
  local rfid_token_val=""
  local zebra_url_val=""
  local rfid_url_val=""

  if [[ "${target_lc}" == "all" || "${target_lc}" == *"zebra"* ]]; then
    telegram_token_val="${telegram_token}"
    zebra_url_val="${zebra_url}"
  fi
  if [[ "${target_lc}" == "all" || "${target_lc}" == *"rfid"* ]]; then
    rfid_token_val="${telegram_token}"
    rfid_url_val="${rfid_url}"
  fi

  local payload
  payload="{\"telegram_token\":\"${telegram_token_val}\",\"rfid_telegram_token\":\"${rfid_token_val}\",\"zebra_url\":\"${zebra_url_val}\",\"rfid_url\":\"${rfid_url_val}\"}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsS -X POST "http://127.0.0.1:${LCE_PORT}/api/config" \
      -H "content-type: application/json" \
      -d "${payload}" >/dev/null
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO /dev/null --method=POST --header="content-type: application/json" \
      --body-data="${payload}" "http://127.0.0.1:${LCE_PORT}/api/config"
    return 0
  fi

  echo "ERROR: curl or wget is required to post config." >&2
  exit 1
}

to_compose_bool() {
  local raw="${1:-0}"
  case "${raw,,}" in
    1|true|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose -f "${COMPOSE_FILE}" -p lce)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose -f "${COMPOSE_FILE}" -p lce)
    return 0
  fi
  echo "ERROR: docker compose not found." >&2
  exit 1
}

compose() {
  "${COMPOSE_CMD[@]}" "$@"
}

as_bool() {
  local raw="${1:-0}"
  case "${raw,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

start_zebra_tui() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi

  if [[ "${LCE_ZEBRA_TUI_NO_BUILD}" == "1" ]]; then
    if compose exec -it bridge bash -lc "cd /zebra_v1 && env CLI_NO_BUILD=1 ./cli.sh tui --url \"http://127.0.0.1:${ZEBRA_WEB_PORT}\""; then
      return 0
    fi
  fi

  compose exec -it bridge bash -lc "cd /zebra_v1 && ./cli.sh tui --url \"http://127.0.0.1:${ZEBRA_WEB_PORT}\""
}

ZEBRA_DIR="$(detect_zebra_dir)"
RFID_DIR="$(detect_rfid_dir)"

if [[ -z "${LCE_CHILDREN_TARGET:-}" ]]; then
  if [[ -t 0 ]]; then
    echo "Select extension to start:"
    echo "  1) Zebra"
    echo "  2) RFID"
    read -r -p "Choice [1-2] (default: 1): " choice
    choice="$(printf '%s' "${choice}" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    if [[ "${choice}" =~ [12] ]]; then
      choice="${BASH_REMATCH[0]}"
    fi

    case "${choice}" in
      2) LCE_CHILDREN_TARGET="rfid" ;;
      1|"")
        LCE_CHILDREN_TARGET="zebra"
        LCE_SHOW_ZEBRA_TUI="1"
        ;;
      *)
        echo "ERROR: invalid choice." >&2
        exit 1
        ;;
    esac
  else
    LCE_CHILDREN_TARGET="zebra"
  fi
fi

need_zebra=0
need_rfid=0
if [[ "${LCE_CHILDREN_TARGET}" == "all" || "${LCE_CHILDREN_TARGET}" == *"zebra"* ]]; then
  need_zebra=1
fi
if [[ "${LCE_CHILDREN_TARGET}" == "all" || "${LCE_CHILDREN_TARGET}" == *"rfid"* ]]; then
  need_rfid=1
fi

missing_zebra=0
missing_rfid=0
if [[ "${need_zebra}" -eq 1 ]] && [[ -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" || ! -f "${ZEBRA_DIR}/run.sh" ]]; then
  missing_zebra=1
fi
if [[ "${need_rfid}" -eq 1 ]] && [[ -z "${RFID_DIR}" || ! -d "${RFID_DIR}" || ! -f "${RFID_DIR}/start-web.sh" ]]; then
  missing_rfid=1
fi

if [[ "${LCE_AUTO_FETCH_CHILDREN}" == "1" ]] && [[ "${missing_zebra}" -eq 1 || "${missing_rfid}" -eq 1 ]]; then
  if [[ ! -f "${FETCH_CHILDREN_SCRIPT}" ]]; then
    echo "ERROR: Missing fetch script: ${FETCH_CHILDREN_SCRIPT}" >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to auto-download child repos." >&2
    exit 1
  fi

  fetch_zebra=0
  fetch_rfid=0
  if [[ "${missing_zebra}" -eq 1 ]] && [[ -z "${LCE_ZEBRA_HOST_DIR:-}" ]]; then
    fetch_zebra=1
  fi
  if [[ "${missing_rfid}" -eq 1 ]] && [[ -z "${LCE_RFID_HOST_DIR:-}" ]]; then
    fetch_rfid=1
  fi

  if [[ "${fetch_zebra}" -eq 1 || "${fetch_rfid}" -eq 1 ]]; then
    LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA="${fetch_zebra}" LCE_FETCH_RFID="${fetch_rfid}" \
      bash "${FETCH_CHILDREN_SCRIPT}"
    ZEBRA_DIR="$(detect_zebra_dir)"
    RFID_DIR="$(detect_rfid_dir)"
  fi
fi

if [[ "${need_zebra}" -eq 1 ]] && [[ -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" || ! -f "${ZEBRA_DIR}/run.sh" ]]; then
  echo "ERROR: zebra directory not found or invalid (missing run.sh)." >&2
  exit 1
fi
if [[ "${need_rfid}" -eq 1 ]] && [[ -z "${RFID_DIR}" || ! -d "${RFID_DIR}" || ! -f "${RFID_DIR}/start-web.sh" ]]; then
  echo "ERROR: rfid directory not found or invalid (missing start-web.sh)." >&2
  exit 1
fi

LCE_TOKEN_FILE="${LCE_TOKEN_FILE:-${LCE_DIR}/.tg_token}"
SAVED_TOKEN=""
if [[ -f "${LCE_TOKEN_FILE}" ]]; then
  SAVED_TOKEN="$(cat "${LCE_TOKEN_FILE}" 2>/dev/null || true)"
  SAVED_TOKEN="$(trim_token "${SAVED_TOKEN}")"
fi

SAVED_VALID=0
if [[ -n "${SAVED_TOKEN}" ]] && valid_telegram_token "${SAVED_TOKEN}"; then
  SAVED_VALID=1
  echo "Saqlangan token: $(mask_token "${SAVED_TOKEN}")"
fi

if [[ ! -t 0 ]]; then
  if valid_telegram_token "${TG_TOKEN:-}"; then
    TG_TOKEN="$(trim_token "${TG_TOKEN}")"
  elif [[ "${SAVED_VALID}" -eq 1 ]]; then
    TG_TOKEN="${SAVED_TOKEN}"
  else
    echo "ERROR: Telegram token required (set TG_TOKEN) and format must be like 123456789:AA..." >&2
    exit 1
  fi
else
  while true; do
    if [[ "${SAVED_VALID}" -eq 1 ]]; then
      read_secret_with_mask "Yangi token (Enter = eski token saqlanadi): "
    else
      read_secret_with_mask "Telegram bot token: "
    fi

    ENTERED_TOKEN="$(trim_token "${REPLY}")"
    if [[ -z "${ENTERED_TOKEN}" ]]; then
      if [[ "${SAVED_VALID}" -eq 1 ]]; then
        TG_TOKEN="${SAVED_TOKEN}"
        break
      fi
      echo "ERROR: Telegram token kiriting."
      continue
    fi

    if valid_telegram_token "${ENTERED_TOKEN}"; then
      TG_TOKEN="${ENTERED_TOKEN}"
      break
    fi

    echo "ERROR: token formati noto'g'ri (masalan: 123456789:AA...)."
  done
fi

printf '%s' "${TG_TOKEN}" > "${LCE_TOKEN_FILE}"
chmod 600 "${LCE_TOKEN_FILE}"

mkdir -p \
  "${LCE_MIX_CACHE_DIR}" \
  "${LCE_BUILD_CACHE_DIR}" \
  "${LCE_DEPS_CACHE_DIR}" \
  "${LCE_PG_DATA_DIR}" \
  "${LCE_NUGET_CACHE_DIR}"

EMPTY_ZEBRA_DIR="${WORK_DIR}/.cache/empty-zebra"
EMPTY_RFID_DIR="${WORK_DIR}/.cache/empty-rfid"
mkdir -p "${EMPTY_ZEBRA_DIR}" "${EMPTY_RFID_DIR}"

if [[ -z "${ZEBRA_DIR}" ]]; then
  ZEBRA_DIR="${EMPTY_ZEBRA_DIR}"
fi
if [[ -z "${RFID_DIR}" ]]; then
  RFID_DIR="${EMPTY_RFID_DIR}"
fi

CORE_RFID_ENABLED="0"
if [[ "${LCE_CHILDREN_TARGET}" == "all" || "${LCE_CHILDREN_TARGET}" == *"rfid"* ]]; then
  CORE_RFID_ENABLED="1"
fi

if as_bool "${LCE_SIM_MODE}"; then
  if [[ -z "${ZEBRA_SCALE_SIMULATE:-}" ]]; then
    export ZEBRA_SCALE_SIMULATE="1"
  fi
  if [[ -z "${ZEBRA_PRINTER_SIMULATE:-}" ]]; then
    ZEBRA_PRINTER_SIMULATE="1"
  fi
  if [[ -z "${LCE_DOCKER_PRIVILEGED:-}" || "${LCE_DOCKER_PRIVILEGED}" == "1" ]]; then
    LCE_DOCKER_PRIVILEGED="0"
  fi
fi

LCE_DOCKER_PRIVILEGED="$(to_compose_bool "${LCE_DOCKER_PRIVILEGED}")"
export LCE_DOCKER_PRIVILEGED
export LCE_DEV_IMAGE
export LCE_PORT ZEBRA_WEB_PORT RFID_WEB_PORT
export LCE_WORK_DIR
export LCE_MIX_CACHE_DIR LCE_BUILD_CACHE_DIR LCE_DEPS_CACHE_DIR LCE_PG_DATA_DIR LCE_NUGET_CACHE_DIR
export LCE_CHILDREN_TARGET
export LCE_ZEBRA_HOST_DIR="${ZEBRA_DIR}"
export LCE_RFID_HOST_DIR="${RFID_DIR}"
export ZEBRA_AUTOPRINT_ENABLED ZEBRA_FEED_AFTER_ENCODE
export ZEBRA_PRINTER_SIMULATE
export CORE_RFID_ENABLED

ensure_cloak_key

if [[ "${LCE_DRY_RUN}" == "1" ]]; then
  echo "DRY RUN"
  echo "WORK_DIR:  ${WORK_DIR}"
  echo "TARGET:    ${LCE_CHILDREN_TARGET}"
  echo "ZEBRA_DIR: ${ZEBRA_DIR}"
  echo "RFID_DIR:  ${RFID_DIR}"
  echo "SIM_MODE:  ${LCE_SIM_MODE}"
  echo "PREBUILT:  ${LCE_USE_PREBUILT_DEV_IMAGE}"
  echo "IMAGE:     ${LCE_DEV_IMAGE}"
  echo "PORTS:     bridge=${LCE_PORT} zebra=${ZEBRA_WEB_PORT} rfid=${RFID_WEB_PORT}"
  exit 0
fi

detect_compose

if [[ "${LCE_DOCKER_HOST_NETWORK}" == "1" ]]; then
  echo "WARNING: Compose run bridge-network rejimida ishlaydi; LCE_DOCKER_HOST_NETWORK compose rejimida qo'llanilmaydi." >&2
fi

if [[ "${LCE_FORCE_RESTART}" == "1" ]]; then
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f lce-core-agent-dev lce-bridge-dev lce-postgres-dev >/dev/null 2>&1 || true
fi

if as_bool "${LCE_USE_PREBUILT_DEV_IMAGE}"; then
  if ! docker image inspect "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
    if ! docker pull "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
      echo "ERROR: prebuilt image pull failed: ${LCE_DEV_IMAGE}" >&2
      echo "TIP: set LCE_USE_PREBUILT_DEV_IMAGE=0 to build locally." >&2
      exit 1
    fi
  fi
  compose up -d --no-build postgres bridge core-agent
else
  compose up -d --build postgres bridge core-agent
fi

if ! wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}"; then
  echo "ERROR: bridge did not become healthy." >&2
  compose logs --tail=100 bridge >&2 || true
  exit 1
fi

ZEBRA_URL="http://127.0.0.1:${ZEBRA_WEB_PORT}"
RFID_URL="http://127.0.0.1:${RFID_WEB_PORT}"
post_config "${TG_TOKEN}" "${ZEBRA_URL}" "${RFID_URL}"

if ! wait_for_core_ready; then
  echo "WARNING: core-agent hali ro'yxatdan o'tmadi (/api/status)." >&2
fi

OPEN_URL="http://127.0.0.1:${LCE_PORT}/api/status"
if [[ "${LCE_CHILDREN_TARGET}" == *"rfid"* ]] || [[ "${LCE_CHILDREN_TARGET}" == "all" ]]; then
  OPEN_URL="http://127.0.0.1:${RFID_WEB_PORT}/"
elif [[ "${LCE_CHILDREN_TARGET}" == *"zebra"* ]]; then
  OPEN_URL="http://127.0.0.1:${ZEBRA_WEB_PORT}/"
fi

if [[ "${LCE_SHOW_ZEBRA_TUI:-0}" == "1" ]]; then
  start_zebra_tui || true
fi

echo "tayyor! ${OPEN_URL}"
echo "To'xtatish: ${COMPOSE_CMD[*]} down"
