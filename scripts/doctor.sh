#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FETCH_CHILDREN_SCRIPT="${SCRIPT_DIR}/fetch_children.sh"
LCE_AUTO_FETCH_CHILDREN="${LCE_AUTO_FETCH_CHILDREN:-1}"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"
LCE_PORT="${LCE_PORT:-4000}"
ZEBRA_WEB_PORT="${ZEBRA_WEB_PORT:-18000}"
RFID_WEB_PORT="${RFID_WEB_PORT:-8787}"
LCE_POSTGRES_PORT="${LCE_POSTGRES_PORT:-5432}"

find_listen_pid() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lptn "( sport = :${port} )" 2>/dev/null | awk -F'pid=' 'NR>1 && $2 { split($2, a, ","); print a[1]; exit }'
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
    return
  fi
  echo ""
}

docker_uses_port() {
  local port="$1"
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -Eq "(^|[[:space:]])[^[:space:]]+[[:space:]].*(:|:::|0\\.0\\.0\\.0:)${port}->"
}

check_port_conflict() {
  local port="$1"
  local name="$2"
  local pid
  pid="$(find_listen_pid "${port}")"
  if [[ -z "${pid}" ]]; then
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker_uses_port "${port}"; then
    echo "INFO: Port ${port} (${name}) docker container tomonidan band (ok)."
    return 0
  fi

  local proc
  proc="$(ps -p "${pid}" -o comm= 2>/dev/null | xargs || true)"
  echo "ERROR: Port ${port} (${name}) band: pid=${pid} proc=${proc:-unknown}" >&2
  echo "TIP: Jarayonni to'xtating yoki boshqa port bering (LCE_PORT/ZEBRA_WEB_PORT/RFID_WEB_PORT/LCE_POSTGRES_PORT)." >&2
  exit 1
}

docker_rootless() {
  local rootless=""
  rootless="$(docker info --format '{{.Rootless}}' 2>/dev/null || true)"
  if [[ "${rootless}" == "true" ]]; then
    return 0
  fi
  if [[ "${rootless}" == "false" ]]; then
    return 1
  fi
  local sec=""
  sec="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
  [[ "${sec}" == *rootless* ]]
}

check_device_access() {
  local any=0
  local warn=0
  local dev=""
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/usb/lp*; do
    [[ -e "${dev}" ]] || continue
    any=1
    if [[ ! -r "${dev}" || ! -w "${dev}" ]]; then
      echo "WARNING: Device access cheklangan: ${dev} (rw kerak)" >&2
      warn=1
    fi
  done

  if [[ "${any}" -eq 0 ]]; then
    echo "INFO: /dev/ttyUSB*, /dev/ttyACM*, /dev/usb/lp* qurilmalar topilmadi."
  elif [[ "${warn}" -eq 1 ]]; then
    echo "TIP: foydalanuvchini mos guruhlarga qo'shing (odatda: dialout, lp) va qayta login qiling." >&2
  else
    echo "Device access: OK"
  fi
}

detect_child_dirs() {
  ZEBRA_DIR="${LCE_ZEBRA_HOST_DIR:-}"
  if [[ -z "${ZEBRA_DIR}" ]]; then
    if [[ -d "${WORK_DIR}/zebra_v1" ]]; then
      ZEBRA_DIR="${WORK_DIR}/zebra_v1"
    elif [[ -d "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version" ]]; then
      ZEBRA_DIR="${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
    elif [[ -d "${LCE_DIR}/zebra_v1" ]]; then
      ZEBRA_DIR="${LCE_DIR}/zebra_v1"
    elif [[ -d "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version" ]]; then
      ZEBRA_DIR="${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version"
    fi
  fi

  RFID_DIR="${LCE_RFID_HOST_DIR:-}"
  if [[ -z "${RFID_DIR}" ]]; then
    if [[ -d "${WORK_DIR}/rfid" ]]; then
      RFID_DIR="${WORK_DIR}/rfid"
    elif [[ -d "${WORK_DIR}/ERPNext_UHFReader288_integration" ]]; then
      RFID_DIR="${WORK_DIR}/ERPNext_UHFReader288_integration"
    elif [[ -d "${LCE_DIR}/rfid" ]]; then
      RFID_DIR="${LCE_DIR}/rfid"
    elif [[ -d "${LCE_DIR}/ERPNext_UHFReader288_integration" ]]; then
      RFID_DIR="${LCE_DIR}/ERPNext_UHFReader288_integration"
    fi
  fi
}

detect_child_dirs

need_zebra=0
need_rfid=0
if [[ ! -d "${ZEBRA_DIR}" ]]; then
  need_zebra=1
fi
if [[ ! -d "${RFID_DIR}" ]]; then
  need_rfid=1
fi

if [[ "${LCE_AUTO_FETCH_CHILDREN}" == "1" && ( "${need_zebra}" == "1" || "${need_rfid}" == "1" ) ]]; then
  if command -v git >/dev/null 2>&1; then
    echo "INFO: Child repos topilmadi. Avtomatik yuklab olyapman (git clone)..." >&2
    LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA="${need_zebra}" LCE_FETCH_RFID="${need_rfid}" \
      bash "${FETCH_CHILDREN_SCRIPT}"
    # Re-detect after fetch.
    detect_child_dirs
  fi
fi

echo "LCE_DIR:   ${LCE_DIR}"
echo "WORK_DIR:  ${WORK_DIR}"
echo "ZEBRA_DIR: ${ZEBRA_DIR:-<missing>}"
echo "RFID_DIR:  ${RFID_DIR:-<missing>}"

if [[ ! -d "${ZEBRA_DIR}" ]]; then
  echo "WARNING: zebra directory not found. Expected zebra_v1/ or ERPNext_Zebra_stabil_enterprise_version/." >&2
  echo "TIP: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
  echo "Or set LCE_ZEBRA_HOST_DIR=/path/to/zebra" >&2
else
  if [[ ! -f "${ZEBRA_DIR}/run.sh" ]]; then
    echo "ERROR: zebra directory found but missing run.sh: ${ZEBRA_DIR}/run.sh" >&2
    echo "Expected repo: https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git" >&2
    exit 1
  fi
fi

if [[ ! -d "${RFID_DIR}" ]]; then
  echo "WARNING: rfid directory not found. Expected rfid/ or ERPNext_UHFReader288_integration/." >&2
  echo "TIP: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
  echo "Or set LCE_RFID_HOST_DIR=/path/to/rfid" >&2
else
  if [[ ! -f "${RFID_DIR}/start-web.sh" ]]; then
    echo "ERROR: rfid directory found but missing start-web.sh: ${RFID_DIR}/start-web.sh" >&2
    echo "Expected repo: https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git" >&2
    exit 1
  fi
fi

if [[ ! -d "${ZEBRA_DIR}" && ! -d "${RFID_DIR}" ]]; then
  echo "ERROR: No child repos found (zebra/rfid)." >&2
  if [[ "${LCE_AUTO_FETCH_CHILDREN}" == "1" ]]; then
    echo "Auto-fetch yoqilgan bo'lsa ham yuklab bo'lmadi. Internet/git ni tekshiring." >&2
  fi
  echo "Run: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
  exit 1
fi

if ! bash -n "${LCE_DIR}/scripts/run_extensions.sh"; then
  echo "ERROR: scripts/run_extensions.sh has a syntax error." >&2
  exit 1
fi

if ! bash -n "${LCE_DIR}/scripts/run_extensions_compose.sh"; then
  echo "ERROR: scripts/run_extensions_compose.sh has a syntax error." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "WARNING: git not found. Auto-download of child repos will not work." >&2
  echo "TIP: make bootstrap" >&2
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "Docker: OK"
  else
    echo "ERROR: Docker is installed but the daemon is not running (docker info failed)." >&2
    echo "TIP: sudo systemctl start docker" >&2
    echo "TIP: make bootstrap" >&2
    exit 1
  fi
else
  echo "WARNING: Docker not found. This will fall back to local 'mix' if available." >&2
  if ! command -v mix >/dev/null 2>&1; then
    echo "ERROR: Neither Docker nor mix are available. Install Docker (recommended) or Elixir/Mix." >&2
    echo "TIP: make bootstrap" >&2
    exit 1
  fi
fi

if docker compose version >/dev/null 2>&1; then
  echo "Docker Compose: OK (docker compose)"
elif command -v docker-compose >/dev/null 2>&1; then
  echo "Docker Compose: OK (docker-compose)"
else
  echo "ERROR: Docker Compose not found (docker compose / docker-compose)." >&2
  echo "TIP: make bootstrap" >&2
  exit 1
fi

if docker buildx version >/dev/null 2>&1; then
  echo "Docker buildx: OK"
else
  echo "WARNING: Docker buildx plugin topilmadi. Birinchi image build juda sekin bo'lishi mumkin (kuchsiz PC'larda ayniqsa)." >&2
  echo "TIP: make bootstrap (docker-buildx-plugin o'rnatadi) yoki prebuilt image ishlating: LCE_USE_PREBUILT_DEV_IMAGE=1 make run" >&2
fi

if docker_rootless; then
  echo "WARNING: Docker rootless rejimi aniqlandi. Hardware mapping (USB/serial/printer) barqaror bo'lmasligi mumkin." >&2
fi

check_port_conflict "${LCE_PORT}" "bridge"
check_port_conflict "${ZEBRA_WEB_PORT}" "zebra"
check_port_conflict "${RFID_WEB_PORT}" "rfid"
check_port_conflict "${LCE_POSTGRES_PORT}" "postgres"

check_device_access

DOCKERFILE_DEV="${LCE_DEV_DOCKERFILE:-${LCE_DIR}/src/bridge/Dockerfile.dev}"
if [[ -f "${DOCKERFILE_DEV}" ]]; then
  echo "Dockerfile.dev: OK"
else
  echo "ERROR: Missing ${DOCKERFILE_DEV}" >&2
  exit 1
fi

echo "Doctor: OK"
