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
LCE_CHILD_WAIT_ATTEMPTS="${LCE_CHILD_WAIT_ATTEMPTS:-240}"
LCE_CHILD_WAIT_DELAY="${LCE_CHILD_WAIT_DELAY:-0.25}"
LCE_FAIL_ON_CHILD_NOT_READY="${LCE_FAIL_ON_CHILD_NOT_READY:-1}"
LCE_FORCE_RESTART="${LCE_FORCE_RESTART:-1}"
LCE_AUTO_FETCH_CHILDREN="${LCE_AUTO_FETCH_CHILDREN:-1}"
LCE_DRY_RUN="${LCE_DRY_RUN:-0}"
LCE_DEV_IMAGE="${LCE_DEV_IMAGE:-}"
LCE_USE_PREBUILT_DEV_IMAGE_USER_SET=0
if [[ -n "${LCE_USE_PREBUILT_DEV_IMAGE+x}" ]]; then
  LCE_USE_PREBUILT_DEV_IMAGE_USER_SET=1
fi
LCE_USE_PREBUILT_DEV_IMAGE="${LCE_USE_PREBUILT_DEV_IMAGE:-0}"
LCE_PREBUILT_AUTO="${LCE_PREBUILT_AUTO:-1}"
LCE_REBUILD_IMAGE="${LCE_REBUILD_IMAGE:-0}"
LCE_BRIDGE_IMAGE_TARGET="${LCE_BRIDGE_IMAGE_TARGET:-}"
LCE_ALLOW_TARGET_MISMATCH="${LCE_ALLOW_TARGET_MISMATCH:-0}"
LCE_CORE_IMAGE="${LCE_CORE_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
LCE_ENABLE_CORE_AGENT="${LCE_ENABLE_CORE_AGENT:-auto}"
LCE_WAIT_CORE_READY="${LCE_WAIT_CORE_READY:-0}"
LCE_SIM_MODE="${LCE_SIM_MODE:-0}"
LCE_DOCKER_PRIVILEGED="${LCE_DOCKER_PRIVILEGED:-1}"
LCE_DOCKER_HOST_NETWORK="${LCE_DOCKER_HOST_NETWORK:-0}"
LCE_ZEBRA_TUI_NO_BUILD="${LCE_ZEBRA_TUI_NO_BUILD:-1}"
ZEBRA_AUTOPRINT_ENABLED="${ZEBRA_AUTOPRINT_ENABLED:-0}"
ZEBRA_FEED_AFTER_ENCODE="${ZEBRA_FEED_AFTER_ENCODE:-0}"
ZEBRA_PRINTER_SIMULATE="${ZEBRA_PRINTER_SIMULATE:-}"
RFID_SCAN_SUBNETS="${RFID_SCAN_SUBNETS:-}"
LCE_RFID_FORCE_LOCAL_PROFILE="${LCE_RFID_FORCE_LOCAL_PROFILE:-1}"
TG_TOKEN="${TG_TOKEN:-}"

LCE_MIX_CACHE_DIR="${LCE_MIX_CACHE_DIR:-${WORK_DIR}/.cache/lce-mix}"
LCE_BUILD_CACHE_DIR="${LCE_BUILD_CACHE_DIR:-${WORK_DIR}/.cache/lce-build}"
LCE_DEPS_CACHE_DIR="${LCE_DEPS_CACHE_DIR:-${WORK_DIR}/.cache/lce-deps}"
LCE_PG_DATA_DIR="${LCE_PG_DATA_DIR:-${WORK_DIR}/.cache/lce-postgres-data}"
LCE_NUGET_CACHE_DIR="${LCE_NUGET_CACHE_DIR:-${WORK_DIR}/.cache/lce-nuget}"
LCE_BRIDGE_NUGET_CACHE_DIR="${LCE_BRIDGE_NUGET_CACHE_DIR:-${WORK_DIR}/.cache/lce-bridge-nuget}"
LCE_CORE_PUBLISH_CACHE_DIR="${LCE_CORE_PUBLISH_CACHE_DIR:-${WORK_DIR}/.cache/lce-core-publish}"
LCE_IMAGE_META_DIR="${LCE_IMAGE_META_DIR:-${WORK_DIR}/.cache/lce-image-meta}"
LCE_CLOAK_KEY_FILE="${LCE_CLOAK_KEY_FILE:-${WORK_DIR}/.cache/lce-cloak.key}"
LCE_DEV_IMAGE_USER_SET=0
if [[ -n "${LCE_DEV_IMAGE}" ]]; then
  LCE_DEV_IMAGE_USER_SET=1
fi

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

detect_host_subnets() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi

  local out=""
  out="$(
    ip -o -4 addr show up scope global 2>/dev/null \
      | awk '
        {
          iface = $2
          cidr = $4
          if (iface ~ /^(lo|docker[0-9]*|br-|veth|virbr|zt|tailscale|wg|tun)/) next
          print cidr
        }
      ' \
      | awk '!seen[$0]++' \
      | paste -sd, -
  )"

  printf '%s' "${out}"
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

wait_for_children_ready() {
  local attempts="${LCE_CHILD_WAIT_ATTEMPTS:-240}"
  local delay="${LCE_CHILD_WAIT_DELAY:-0.25}"
  local target="${LCE_CHILDREN_TARGET:-zebra}"
  local target_lc="${target,,}"
  local failed=0

  if [[ "${target_lc}" == "all" || "${target_lc}" == *"zebra"* ]]; then
    if ! wait_for_url "http://127.0.0.1:${ZEBRA_WEB_PORT}/api/v1/health" "${attempts}" "${delay}"; then
      echo "WARNING: zebra endpoint hali tayyor emas (http://127.0.0.1:${ZEBRA_WEB_PORT}/api/v1/health)." >&2
      failed=1
    fi
  fi

  if [[ "${target_lc}" == "all" || "${target_lc}" == *"rfid"* ]]; then
    if ! wait_for_url "http://127.0.0.1:${RFID_WEB_PORT}/" "${attempts}" "${delay}"; then
      echo "WARNING: rfid endpoint hali tayyor emas (http://127.0.0.1:${RFID_WEB_PORT}/)." >&2
      failed=1
    fi
  fi

  return "${failed}"
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

has_buildx() {
  docker buildx version >/dev/null 2>&1
}

derive_ghcr_image() {
  # Best-effort: derive ghcr.io/<owner>/xlcu-bridge-dev:<target> from git origin.
  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi

  local remote=""
  remote="$(git -C "${LCE_DIR}" remote get-url origin 2>/dev/null || true)"
  remote="$(trim_token "${remote}")"
  if [[ -z "${remote}" ]]; then
    return 1
  fi

  local owner=""
  case "${remote}" in
    *github.com* )
      owner="$(printf '%s' "${remote}" | sed -E 's#^.*github\\.com[:/]([^/]+)/.*$#\\1#')"
      ;;
  esac

  owner="$(printf '%s' "${owner}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${owner}" || "${owner}" == "${remote}" ]]; then
    return 1
  fi

  printf 'ghcr.io/%s/xlcu-bridge-dev:%s' "${owner}" "${LCE_BRIDGE_IMAGE_TARGET}"
}

filter_legacy_builder_warning() {
  sed \
    -e '/^DEPRECATED: The legacy builder is deprecated and will be removed in a future release\.$/d' \
    -e '/^            Install the buildx component to build images with BuildKit:$/d' \
    -e '/^            https:\/\/docs.docker.com\/go\/buildx\/$/d'
}

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  openssl dgst -sha256 | awk '{print $NF}'
}

sha256_of_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
    return 0
  fi
  openssl dgst -sha256 "${file}" | awk '{print $NF}'
}

bridge_image_fingerprint() {
  local bridge_dir="${LCE_DIR}/src/bridge"
  local files=(
    "Dockerfile.dev"
    "mix.exs"
    "mix.lock"
    "config/config.exs"
    "config/dev.exs"
  )

  {
    printf 'target=%s\n' "${LCE_BRIDGE_IMAGE_TARGET}"
    for rel in "${files[@]}"; do
      local path="${bridge_dir}/${rel}"
      if [[ -f "${path}" ]]; then
        printf '%s=%s\n' "${rel}" "$(sha256_of_file "${path}")"
      else
        printf '%s=missing\n' "${rel}"
      fi
    done
  } | sha256_of_stdin
}

bridge_image_fingerprint_file() {
  local key
  key="$(printf '%s|%s' "${LCE_DEV_IMAGE}" "${LCE_BRIDGE_IMAGE_TARGET}" | sha256_of_stdin)"
  printf '%s/%s.fingerprint' "${LCE_IMAGE_META_DIR}" "${key}"
}

build_local_dev_image() {
  local bridge_dir="${LCE_DIR}/src/bridge"
  local dockerfile="${bridge_dir}/Dockerfile.dev"
  local fp_file=""
  local current_fp=""
  local cached_fp=""

  if [[ ! -f "${dockerfile}" ]]; then
    echo "ERROR: Dockerfile topilmadi: ${dockerfile}" >&2
    exit 1
  fi

  mkdir -p "${LCE_IMAGE_META_DIR}"
  fp_file="$(bridge_image_fingerprint_file)"
  current_fp="$(bridge_image_fingerprint)"

  if ! as_bool "${LCE_REBUILD_IMAGE}" && docker image inspect "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
    if [[ -f "${fp_file}" ]]; then
      cached_fp="$(cat "${fp_file}" 2>/dev/null || true)"
      cached_fp="$(trim_token "${cached_fp}")"
      if [[ -n "${cached_fp}" ]] && [[ "${cached_fp}" == "${current_fp}" ]]; then
        echo "Local dev image build: cache hit, skip (${LCE_DEV_IMAGE}, target=${LCE_BRIDGE_IMAGE_TARGET})"
        return 0
      fi
    fi
  fi

  echo "Local dev image build: ${LCE_DEV_IMAGE} (target=${LCE_BRIDGE_IMAGE_TARGET})"
  if ! has_buildx; then
    echo "WARNING: docker buildx plugin topilmadi. Legacy builder ishlatiladi va birinchi build juda sekin bo'lishi mumkin." >&2
    echo "TIP: make bootstrap (buildx o'rnatadi) yoki prebuilt image ishlating: LCE_USE_PREBUILT_DEV_IMAGE=1 make run" >&2
  fi
  if has_buildx; then
    if ! DOCKER_BUILDKIT=1 docker build --target "${LCE_BRIDGE_IMAGE_TARGET}" -t "${LCE_DEV_IMAGE}" -f "${dockerfile}" "${bridge_dir}"; then
      echo "ERROR: local image build failed: ${LCE_DEV_IMAGE}" >&2
      exit 1
    fi
    printf '%s' "${current_fp}" > "${fp_file}"
    return 0
  fi

  if ! DOCKER_BUILDKIT=0 docker build --target "${LCE_BRIDGE_IMAGE_TARGET}" -t "${LCE_DEV_IMAGE}" -f "${dockerfile}" "${bridge_dir}" \
    2> >(filter_legacy_builder_warning >&2); then
    echo "ERROR: local image build failed: ${LCE_DEV_IMAGE}" >&2
    exit 1
  fi
  printf '%s' "${current_fp}" > "${fp_file}"
}

as_bool() {
  local raw="${1:-0}"
  case "${raw,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

core_agent_enabled() {
  local mode="${LCE_ENABLE_CORE_AGENT:-auto}"
  case "${mode,,}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    auto)
      if [[ "${LCE_CHILDREN_TARGET}" == "rfid" ]]; then
        return 1
      fi
      return 0
      ;;
    *)
      echo "ERROR: LCE_ENABLE_CORE_AGENT must be one of: auto, 0, 1" >&2
      exit 1
      ;;
  esac
}

force_rfid_local_profile() {
  if ! as_bool "${LCE_RFID_FORCE_LOCAL_PROFILE:-1}"; then
    return 0
  fi

  local target="${LCE_CHILDREN_TARGET:-zebra}"
  local target_lc="${target,,}"
  if [[ "${target_lc}" != "all" && "${target_lc}" != *"rfid"* ]]; then
    return 0
  fi

  local dir="${RFID_DIR:-}"
  if [[ -z "${dir}" || ! -d "${dir}" ]]; then
    return 0
  fi

  local cfg="${dir}/Demo/web-localhost/server/local-config.json"
  local py
  py="$(python_bin 2>/dev/null || true)"
  if [[ -z "${py}" ]]; then
    echo "WARNING: python topilmadi, RFID local profile auto-fix o'tkazib yuborildi." >&2
    return 0
  fi

  "${py}" - "${cfg}" <<'PY'
import json
import socket
import sys
from pathlib import Path

cfg_path = Path(sys.argv[1])
cfg_path.parent.mkdir(parents=True, exist_ok=True)

data = {}
if cfg_path.exists():
  try:
    data = json.loads(cfg_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
      data = {}
  except Exception:
    data = {}

erp = data.get("erp")
if not isinstance(erp, dict):
  erp = {}

profiles = erp.get("profiles")
if not isinstance(profiles, dict):
  profiles = {}

local_profile = profiles.get("local")
if not isinstance(local_profile, dict):
  local_profile = {}

host = socket.gethostname() or "uhf-local"
device = str(local_profile.get("device") or erp.get("device") or host).strip() or host
agent_id = str(local_profile.get("agentId") or erp.get("agentId") or device).strip() or device

local_profile["baseUrl"] = ""
local_profile["auth"] = ""
local_profile["device"] = device
local_profile["agentId"] = agent_id
local_profile["pushEnabled"] = False
local_profile["rpcEnabled"] = False
local_profile["overrideEnv"] = True
profiles["local"] = local_profile

erp["profiles"] = profiles
erp["activeProfile"] = "local"
erp["baseUrl"] = ""
erp["auth"] = ""
erp["pushEnabled"] = False
erp["rpcEnabled"] = False
if "overrideEnv" not in erp:
  erp["overrideEnv"] = True

data["erp"] = erp
cfg_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

start_zebra_tui() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    return 1
  fi

  local cols="${COLUMNS:-}"
  local lines="${LINES:-}"
  local term_value="${TERM:-xterm-256color}"
  if [[ -z "${term_value}" || "${term_value}" == "dumb" ]]; then
    term_value="xterm-256color"
  fi
  local colorterm_value="${COLORTERM:-}"
  local stty_size=""
  if [[ -z "${cols}" || -z "${lines}" ]] && stty_size="$(stty size 2>/dev/null || true)"; then
    if [[ "${stty_size}" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
      lines="${lines:-${BASH_REMATCH[1]}}"
      cols="${cols:-${BASH_REMATCH[2]}}"
    fi
  fi

  local -a exec_opts
  exec_opts=(-it -e "TERM=${term_value}")
  if [[ -n "${cols}" ]]; then
    exec_opts+=(-e "COLUMNS=${cols}")
  fi
  if [[ -n "${lines}" ]]; then
    exec_opts+=(-e "LINES=${lines}")
  fi
  if [[ -n "${colorterm_value}" ]]; then
    exec_opts+=(-e "COLORTERM=${colorterm_value}")
  fi

  # Keep terminal state sane after full-screen ANSI UI exits.
  trap 'stty sane 2>/dev/null || true; printf "\033[0m" 2>/dev/null || true' RETURN

  if [[ "${LCE_ZEBRA_TUI_NO_BUILD}" == "1" ]]; then
    if compose exec "${exec_opts[@]}" bridge bash -lc "stty cols \"\${COLUMNS:-80}\" rows \"\${LINES:-24}\" >/dev/null 2>&1 || true; cd /zebra_v1 && env CLI_NO_BUILD=1 ./cli.sh tui --url \"http://127.0.0.1:${ZEBRA_WEB_PORT}\""; then
      return 0
    fi
  fi

  compose exec "${exec_opts[@]}" bridge bash -lc "stty cols \"\${COLUMNS:-80}\" rows \"\${LINES:-24}\" >/dev/null 2>&1 || true; cd /zebra_v1 && ./cli.sh tui --url \"http://127.0.0.1:${ZEBRA_WEB_PORT}\""
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
        if [[ -z "${LCE_SHOW_ZEBRA_TUI:-}" ]]; then
          LCE_SHOW_ZEBRA_TUI="1"
        fi
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

EXPECTED_BRIDGE_IMAGE_TARGET="bridge-all"
case "${LCE_CHILDREN_TARGET}" in
  zebra) EXPECTED_BRIDGE_IMAGE_TARGET="bridge-zebra" ;;
  rfid) EXPECTED_BRIDGE_IMAGE_TARGET="bridge-rfid" ;;
  *) EXPECTED_BRIDGE_IMAGE_TARGET="bridge-all" ;;
esac

if [[ -z "${LCE_BRIDGE_IMAGE_TARGET}" ]]; then
  LCE_BRIDGE_IMAGE_TARGET="${EXPECTED_BRIDGE_IMAGE_TARGET}"
elif [[ "${LCE_BRIDGE_IMAGE_TARGET}" != "${EXPECTED_BRIDGE_IMAGE_TARGET}" ]]; then
  if as_bool "${LCE_ALLOW_TARGET_MISMATCH}"; then
    echo "WARNING: target mismatch allowed (child=${LCE_CHILDREN_TARGET}, image_target=${LCE_BRIDGE_IMAGE_TARGET})." >&2
  else
    echo "WARNING: image target child tanloviga mos emas (${LCE_BRIDGE_IMAGE_TARGET} -> ${EXPECTED_BRIDGE_IMAGE_TARGET}); avtomatik tuzatildi." >&2
    LCE_BRIDGE_IMAGE_TARGET="${EXPECTED_BRIDGE_IMAGE_TARGET}"
  fi
fi

case "${LCE_BRIDGE_IMAGE_TARGET}" in
  bridge-zebra|bridge-rfid|bridge-all) ;;
  *)
    echo "ERROR: LCE_BRIDGE_IMAGE_TARGET must be one of: bridge-zebra, bridge-rfid, bridge-all" >&2
    exit 1
    ;;
esac

if [[ "${LCE_DEV_IMAGE_USER_SET}" -eq 0 ]]; then
  LCE_DEV_IMAGE="lce-bridge-dev:${LCE_BRIDGE_IMAGE_TARGET}"
fi

# If user did not explicitly choose prebuilt/local mode, try prebuilt images on first run.
# This makes fresh installs fast on low-spec PCs, while still falling back to local builds.
LCE_PREBUILT_AUTO_ACTIVE=0
LCE_LOCAL_DEV_IMAGE="${LCE_DEV_IMAGE}"
if [[ "${LCE_USE_PREBUILT_DEV_IMAGE_USER_SET}" -eq 0 ]] && [[ "${LCE_DEV_IMAGE_USER_SET}" -eq 0 ]] && as_bool "${LCE_PREBUILT_AUTO}"; then
  if ! as_bool "${LCE_REBUILD_IMAGE}" && ! docker image inspect "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
    LCE_USE_PREBUILT_DEV_IMAGE="1"
    LCE_PREBUILT_AUTO_ACTIVE=1
  fi
fi

if as_bool "${LCE_USE_PREBUILT_DEV_IMAGE}" && [[ "${LCE_DEV_IMAGE_USER_SET}" -eq 0 ]]; then
  derived_image="$(derive_ghcr_image 2>/dev/null || true)"
  if [[ -n "${derived_image}" ]]; then
    LCE_DEV_IMAGE="${derived_image}"
    echo "Prebuilt image: ${LCE_DEV_IMAGE}"
  else
    if [[ "${LCE_PREBUILT_AUTO_ACTIVE}" -eq 1 ]]; then
      echo "WARNING: prebuilt image auto-mode: GHCR image aniqlanmadi. Local build'ga o'tyapman." >&2
      LCE_USE_PREBUILT_DEV_IMAGE="0"
      LCE_DEV_IMAGE="${LCE_LOCAL_DEV_IMAGE}"
    else
      echo "ERROR: LCE_USE_PREBUILT_DEV_IMAGE=1, lekin LCE_DEV_IMAGE berilmagan va git origin'dan GHCR image aniqlanmadi." >&2
      echo "TIP: LCE_DEV_IMAGE=ghcr.io/<owner>/xlcu-bridge-dev:${LCE_BRIDGE_IMAGE_TARGET} LCE_USE_PREBUILT_DEV_IMAGE=1 make run" >&2
      exit 1
    fi
  fi
fi

LCE_START_CORE_AGENT=0
if core_agent_enabled; then
  LCE_START_CORE_AGENT=1
fi
DRY_SERVICES="postgres bridge"
if [[ "${LCE_START_CORE_AGENT}" -eq 1 ]]; then
  DRY_SERVICES+=" core-agent"
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
  "${LCE_NUGET_CACHE_DIR}" \
  "${LCE_BRIDGE_NUGET_CACHE_DIR}" \
  "${LCE_CORE_PUBLISH_CACHE_DIR}" \
  "${LCE_IMAGE_META_DIR}"

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

if [[ -z "${RFID_SCAN_SUBNETS}" ]]; then
  RFID_SCAN_SUBNETS="$(detect_host_subnets)"
fi

force_rfid_local_profile

LCE_DOCKER_PRIVILEGED="$(to_compose_bool "${LCE_DOCKER_PRIVILEGED}")"
export LCE_DOCKER_PRIVILEGED
export LCE_DEV_IMAGE
export LCE_BRIDGE_IMAGE_TARGET
export LCE_CORE_IMAGE
export LCE_PORT ZEBRA_WEB_PORT RFID_WEB_PORT
export LCE_WORK_DIR
export LCE_MIX_CACHE_DIR LCE_BUILD_CACHE_DIR LCE_DEPS_CACHE_DIR LCE_PG_DATA_DIR LCE_NUGET_CACHE_DIR LCE_BRIDGE_NUGET_CACHE_DIR LCE_CORE_PUBLISH_CACHE_DIR
export LCE_CHILDREN_TARGET
export LCE_ZEBRA_HOST_DIR="${ZEBRA_DIR}"
export LCE_RFID_HOST_DIR="${RFID_DIR}"
export ZEBRA_AUTOPRINT_ENABLED ZEBRA_FEED_AFTER_ENCODE
export ZEBRA_PRINTER_SIMULATE
export RFID_SCAN_SUBNETS
export CORE_RFID_ENABLED

ensure_cloak_key

if [[ "${LCE_DRY_RUN}" == "1" ]]; then
  echo "DRY RUN"
  echo "WORK_DIR:  ${WORK_DIR}"
  echo "TARGET:    ${LCE_CHILDREN_TARGET}"
  echo "ZEBRA_DIR: ${ZEBRA_DIR}"
  echo "RFID_DIR:  ${RFID_DIR}"
  echo "SIM_MODE:  ${LCE_SIM_MODE}"
  echo "CORE:      ${LCE_START_CORE_AGENT} (mode=${LCE_ENABLE_CORE_AGENT})"
  echo "CORE_WAIT: ${LCE_WAIT_CORE_READY}"
  echo "CHILD_WAIT:${LCE_CHILD_WAIT_ATTEMPTS} x ${LCE_CHILD_WAIT_DELAY}s (fail=${LCE_FAIL_ON_CHILD_NOT_READY})"
  echo "SERVICES:  ${DRY_SERVICES}"
  echo "REBUILD:   ${LCE_REBUILD_IMAGE}"
  echo "PREBUILT:  ${LCE_USE_PREBUILT_DEV_IMAGE}"
  echo "IMAGE:     ${LCE_DEV_IMAGE} (target=${LCE_BRIDGE_IMAGE_TARGET})"
  echo "CORE_IMG:  ${LCE_CORE_IMAGE}"
  echo "BR_NUGET:  ${LCE_BRIDGE_NUGET_CACHE_DIR}"
  echo "CORE_PUB:  ${LCE_CORE_PUBLISH_CACHE_DIR}"
  echo "IMG_META:  ${LCE_IMAGE_META_DIR}"
  echo "PORTS:     bridge=${LCE_PORT} zebra=${ZEBRA_WEB_PORT} rfid=${RFID_WEB_PORT}"
  echo "RFID_SCAN_SUBNETS: ${RFID_SCAN_SUBNETS:-<empty>}"
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

SERVICES=(postgres bridge)
if [[ "${LCE_START_CORE_AGENT}" -eq 1 ]]; then
  SERVICES+=(core-agent)
fi

if as_bool "${LCE_USE_PREBUILT_DEV_IMAGE}"; then
  if ! docker image inspect "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
    if ! docker pull "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
      if [[ "${LCE_PREBUILT_AUTO_ACTIVE}" -eq 1 ]]; then
        echo "WARNING: prebuilt image pull failed; local build'ga o'tyapman: ${LCE_DEV_IMAGE}" >&2
        LCE_USE_PREBUILT_DEV_IMAGE="0"
        LCE_DEV_IMAGE="${LCE_LOCAL_DEV_IMAGE}"
      else
        echo "ERROR: prebuilt image pull failed: ${LCE_DEV_IMAGE}" >&2
        echo "TIP: set LCE_USE_PREBUILT_DEV_IMAGE=0 to build locally." >&2
        exit 1
      fi
    fi
  fi
fi

if as_bool "${LCE_USE_PREBUILT_DEV_IMAGE}"; then
  compose up -d --no-build "${SERVICES[@]}"
else
  build_local_dev_image
  compose up -d --no-build "${SERVICES[@]}"
fi

if ! wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}"; then
  echo "ERROR: bridge did not become healthy." >&2
  compose logs --tail=100 bridge >&2 || true
  exit 1
fi

ZEBRA_URL="http://127.0.0.1:${ZEBRA_WEB_PORT}"
RFID_URL="http://127.0.0.1:${RFID_WEB_PORT}"
post_config "${TG_TOKEN}" "${ZEBRA_URL}" "${RFID_URL}"

if ! wait_for_children_ready; then
  if as_bool "${LCE_FAIL_ON_CHILD_NOT_READY}"; then
    echo "ERROR: child extension endpoint tayyor bo'lmadi." >&2
    compose logs --tail=120 bridge >&2 || true
    exit 1
  fi
fi

if [[ "${LCE_START_CORE_AGENT}" -eq 1 ]]; then
  if as_bool "${LCE_WAIT_CORE_READY}"; then
    if ! wait_for_core_ready; then
      echo "WARNING: core-agent hali ro'yxatdan o'tmadi (/api/status)." >&2
    fi
  fi
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
