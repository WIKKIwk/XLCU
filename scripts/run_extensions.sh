#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FETCH_CHILDREN_SCRIPT="${SCRIPT_DIR}/fetch_children.sh"

# This repo historically kept `zebra_v1/` and `rfid/` next to `LCE/`.
# For portability, auto-detect the "work root" (where logs/cache live) and
# the extension directories, while still allowing overrides.
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
ZEBRA_WEB_HOST="${ZEBRA_WEB_HOST:-0.0.0.0}"
RFID_WEB_HOST="${RFID_WEB_HOST:-0.0.0.0}"
LCE_WAIT_ATTEMPTS="${LCE_WAIT_ATTEMPTS:-900}"
LCE_WAIT_DELAY="${LCE_WAIT_DELAY:-0.5}"
LCE_KEEP_DOCKER="${LCE_KEEP_DOCKER:-1}"
LCE_FORCE_RESTART="${LCE_FORCE_RESTART:-0}"
TG_TOKEN="${TG_TOKEN:-}"
LCE_MIX_CACHE_DIR="${LCE_MIX_CACHE_DIR:-${WORK_DIR}/.cache/lce-mix}"
LCE_BUILD_CACHE_DIR="${LCE_BUILD_CACHE_DIR:-${WORK_DIR}/.cache/lce-build}"
LCE_DEPS_CACHE_DIR="${LCE_DEPS_CACHE_DIR:-${WORK_DIR}/.cache/lce-deps}"
LCE_CLOAK_KEY_FILE="${LCE_CLOAK_KEY_FILE:-${WORK_DIR}/.cache/lce-cloak.key}"
LCE_CHILD_HOST="${LCE_CHILD_HOST:-127.0.0.1}"
LCE_DOCKER=0
LCE_DOCKER_CONTAINER="lce-bridge-dev"
LCE_POSTGRES_CONTAINER="lce-postgres-dev"
LCE_DOCKER_NETWORK="lce-bridge-net"
LCE_DOCKER_DNS_PRIMARY="${LCE_DOCKER_DNS_PRIMARY:-1.1.1.1}"
LCE_DOCKER_DNS_SECONDARY="${LCE_DOCKER_DNS_SECONDARY:-8.8.8.8}"
LCE_DOCKER_RESET="${LCE_DOCKER_RESET:-0}"
LCE_FORCE_DOCKER="${LCE_FORCE_DOCKER:-0}"
LCE_FORCE_LOCAL="${LCE_FORCE_LOCAL:-0}"
LCE_PREFER_DOCKER="${LCE_PREFER_DOCKER:-1}"
LCE_DEV_IMAGE="${LCE_DEV_IMAGE:-lce-bridge-dev:elixir-1.16.2-dotnet-10.0}"
LCE_DEV_DOCKERFILE="${LCE_DEV_DOCKERFILE:-${LCE_DIR}/src/bridge/Dockerfile.dev}"
LCE_DEV_BUILD_CONTEXT="${LCE_DEV_BUILD_CONTEXT:-${LCE_DIR}/src/bridge}"
LCE_DEV_IMAGE_REBUILD="${LCE_DEV_IMAGE_REBUILD:-0}"
LCE_SIMULATE_DEVICES="${LCE_SIMULATE_DEVICES:-1}"
LCE_ZEBRA_TUI_NO_BUILD="${LCE_ZEBRA_TUI_NO_BUILD:-1}"
LCE_QUIET="${LCE_QUIET:-1}"
LCE_AUTO_FETCH_CHILDREN="${LCE_AUTO_FETCH_CHILDREN:-1}"
LCE_DRY_RUN="${LCE_DRY_RUN:-0}"
export LCE_SIMULATE_DEVICES
CORE_PG_PORT="${CORE_PG_PORT:-5433}"
CORE_PG_DB="${CORE_PG_DB:-titan_core_cache}"
CORE_PG_USER="${CORE_PG_USER:-core}"
CORE_PG_PASSWORD="${CORE_PG_PASSWORD:-core_secret}"
CORE_PG_CONTAINER="lce-core-cache-db"
CORE_AGENT_LOG="${LOG_DIR}/core-agent.log"
CORE_AGENT_PID=""
CORE_AGENT_CONTAINER="lce-core-agent-dev"
CORE_AGENT_DOCKER=0

detect_zebra_dir() {
  local dir="${LCE_ZEBRA_HOST_DIR:-}"
  if [[ -n "${dir}" ]]; then
    printf '%s' "${dir}"
    return 0
  fi

  # Support both historical folder name (`zebra_v1/`) and the repo name used on GitHub.
  if [[ -d "${WORK_DIR}/zebra_v1" ]]; then
    dir="${WORK_DIR}/zebra_v1"
  elif [[ -d "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version" ]]; then
    dir="${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
  elif [[ -d "${LCE_DIR}/zebra_v1" ]]; then
    dir="${LCE_DIR}/zebra_v1"
  elif [[ -d "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version" ]]; then
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

  # Support both historical folder name (`rfid/`) and the repo name used on GitHub.
  if [[ -d "${WORK_DIR}/rfid" ]]; then
    dir="${WORK_DIR}/rfid"
  elif [[ -d "${WORK_DIR}/ERPNext_UHFReader288_integration" ]]; then
    dir="${WORK_DIR}/ERPNext_UHFReader288_integration"
  elif [[ -d "${LCE_DIR}/rfid" ]]; then
    dir="${LCE_DIR}/rfid"
  elif [[ -d "${LCE_DIR}/ERPNext_UHFReader288_integration" ]]; then
    dir="${LCE_DIR}/ERPNext_UHFReader288_integration"
  else
    dir=""
  fi

  printf '%s' "${dir}"
}

ZEBRA_DIR="$(detect_zebra_dir)"
RFID_DIR="$(detect_rfid_dir)"

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
  # Encryption key must be stable across restarts; otherwise DB-stored tokens become unreadable.
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
import os, base64
print(base64.b64encode(os.urandom(32)).decode("ascii"))
PY
)"
      else
        # Fallback: coreutils base64
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

read_secret_with_mask() {
  local prompt="$1"
  local secret=""
  local char=""

  if [[ ! -t 0 ]]; then
    REPLY=""
    return 0
  fi

  printf "%s" "$prompt"
  local old_stty
  old_stty="$(stty -g)"
  stty -echo
  while IFS= read -r -n1 char; do
    if [[ -z "$char" ]]; then
      break
    fi
    if [[ "$char" == $'\n' || "$char" == $'\r' ]]; then
      break
    fi
    if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
      if [[ -n "$secret" ]]; then
        secret="${secret%?}"
        printf "\b \b"
      fi
      continue
    fi
    secret+="$char"
    printf "*"
  done
  stty "$old_stty"
  printf "\n"
  REPLY="$secret"
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
    if [[ "${LCE_QUIET}" != "1" ]] && [[ -t 1 ]]; then
      printf "."
    fi
    sleep "${delay}"
  done
  if [[ "${LCE_QUIET}" != "1" ]] && [[ -t 1 ]]; then
    printf "\n"
  fi
  return 1
}

wait_for_url_with_spinner() {
  local url="$1"
  local attempts="${2:-40}"
  local delay="${3:-0.25}"
  local label="${4:-Ishga tushmoqda}"

  if [[ ! -t 1 ]]; then
    wait_for_url "${url}" "${attempts}" "${delay}"
    return $?
  fi

  local -a frames=(
    "[>         ]"
    "[=>        ]"
    "[==>       ]"
    "[===>      ]"
    "[====>     ]"
    "[=====>    ]"
    "[======>   ]"
    "[=======>  ]"
    "[========> ]"
    "[=========>]"
    "[========> ]"
    "[=======>  ]"
    "[======>   ]"
    "[=====>    ]"
    "[====>     ]"
    "[===>      ]"
    "[==>       ]"
    "[=>        ]"
  )
  local -a stages=(
    "creating network"
    "starting container"
    "booting services"
    "running healthcheck"
  )
  local i=0
  local frame=""
  local stage_idx=0
  local stage_window=1
  local percent=0
  local percent_den="${attempts}"
  if [[ "${percent_den}" -lt 1 ]]; then
    percent_den=1
  fi
  local total_stages="${#stages[@]}"
  if [[ "${total_stages}" -gt 0 ]]; then
    stage_window=$((attempts / total_stages))
    if [[ "${stage_window}" -lt 1 ]]; then
      stage_window=1
    fi
  fi

  for _ in $(seq 1 "${attempts}"); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "${url}" >/dev/null 2>&1; then
        printf "\r%s | docker ready           100%% [==========]    \n" "${label}"
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO /dev/null "${url}" >/dev/null 2>&1; then
        printf "\r%s | docker ready           100%% [==========]    \n" "${label}"
        return 0
      fi
    fi

    stage_idx=$((i / stage_window))
    if [[ "${stage_idx}" -ge "${total_stages}" ]]; then
      stage_idx=$((total_stages - 1))
    fi
    percent=$(( (i * 100) / percent_den ))
    frame="${frames[i % ${#frames[@]}]}"
    printf "\r%s | docker %-22s %3d%% %s" "${label}" "${stages[stage_idx]}" "${percent}" "${frame}"
    i=$((i + 1))
    sleep "${delay}"
  done

  printf "\r%s | docker failed          100%% [!!!!!!!!!!]    \n" "${label}"
  return 1
}

run_with_spinner() {
  local label="$1"
  shift || true

  if [[ $# -lt 1 ]]; then
    return 0
  fi

  if [[ ! -t 1 ]]; then
    "$@"
    return $?
  fi

  local -a frames=(
    "[>         ]"
    "[=>        ]"
    "[==>       ]"
    "[===>      ]"
    "[====>     ]"
    "[=====>    ]"
    "[======>   ]"
    "[=======>  ]"
    "[========> ]"
    "[=========>]"
    "[========> ]"
    "[=======>  ]"
    "[======>   ]"
    "[=====>    ]"
    "[====>     ]"
    "[===>      ]"
    "[==>       ]"
    "[=>        ]"
  )

  "$@" &
  local pid=$!
  local i=0
  while kill -0 "${pid}" >/dev/null 2>&1; do
    printf "\r%s %s" "${label}" "${frames[i % ${#frames[@]}]}"
    i=$((i + 1))
    sleep 0.15
  done

  wait "${pid}"
  local code=$?
  if [[ "${code}" -eq 0 ]]; then
    printf "\r%s done.                \n" "${label}"
  else
    printf "\r%s failed (rc=%d).      \n" "${label}" "${code}"
  fi
  return "${code}"
}

post_config() {
  local telegram_token="$1"
  local zebra_url="$2"
  local rfid_url="$3"
  local target="${LCE_CHILDREN_TARGET:-zebra}"

  # Build JSON without Python/jq dependency.
  # Telegram token charset is restricted; URLs here are simple http(s) strings.
  local telegram_token_val=""
  local rfid_token_val=""
  if [[ "${target}" == *"rfid"* ]]; then
    rfid_token_val="${telegram_token}"
  else
    telegram_token_val="${telegram_token}"
  fi

  local payload
  payload="{\"telegram_token\":\"${telegram_token_val}\",\"rfid_telegram_token\":\"${rfid_token_val}\",\"zebra_url\":\"${zebra_url}\",\"rfid_url\":\"${rfid_url}\"}"

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

health_ready() {
  wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" 1 0
}

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

free_port() {
  local port="$1"
  local pid
  pid="$(find_listen_pid "${port}")"
  if [[ -n "${pid}" ]]; then
    kill "${pid}" >/dev/null 2>&1 || true
    sleep 0.3
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -9 "${pid}" >/dev/null 2>&1 || true
      sleep 0.1
    fi
  fi
}

stop_existing_lce() {
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1 || true
  fi

  local pid
  pid="$(find_listen_pid "${LCE_PORT}")"
  if [[ -n "${pid}" ]]; then
    kill "${pid}" >/dev/null 2>&1 || true
    sleep 0.2
  fi
}

ensure_lce_dev_image() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is required to build the dev image." >&2
    exit 1
  fi

  if [[ "${LCE_DEV_IMAGE_REBUILD}" == "1" ]]; then
    docker rmi "${LCE_DEV_IMAGE}" >/dev/null 2>&1 || true
  fi

  if docker image inspect "${LCE_DEV_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -f "${LCE_DEV_DOCKERFILE}" ]]; then
    echo "ERROR: Missing dev Dockerfile: ${LCE_DEV_DOCKERFILE}" >&2
    exit 1
  fi

  if [[ "${LCE_QUIET}" != "1" ]]; then
    echo "Docker image build: ${LCE_DEV_IMAGE}"
  fi

  local build_log="${LOG_DIR}/lce-dev-image-build.log"

  # Some distros ship Docker without a working `buildx` plugin. In that case
  # forcing BuildKit fails with:
  #   "BuildKit is enabled but the buildx component is missing or broken."
  # Auto-fallback to the legacy builder when buildx is unavailable.
  local buildkit_mode="${LCE_DOCKER_BUILDKIT:-auto}" # auto|1|0
  local buildkit_env="1"
  case "${buildkit_mode}" in
    0|false|off)
      buildkit_env="0"
      ;;
    1|true|on)
      buildkit_env="1"
      ;;
    auto|"")
      if docker buildx version >/dev/null 2>&1; then
        buildkit_env="1"
      else
        buildkit_env="0"
      fi
      ;;
    *)
      # Unknown value; be safe and fall back.
      buildkit_env="0"
      ;;
  esac

  if ! DOCKER_BUILDKIT="${buildkit_env}" docker build \
    -t "${LCE_DEV_IMAGE}" \
    -f "${LCE_DEV_DOCKERFILE}" \
    "${LCE_DEV_BUILD_CONTEXT}" >"${build_log}" 2>&1; then
    # If BuildKit failed due to missing buildx, retry with legacy builder.
    if [[ "${buildkit_env}" == "1" ]] && grep -Eq "buildx component is missing|BuildKit is enabled but the buildx" "${build_log}" 2>/dev/null; then
      if [[ "${LCE_QUIET}" != "1" ]]; then
        echo "WARNING: buildx missing/broken; retrying docker build with DOCKER_BUILDKIT=0" >&2
      fi
      if DOCKER_BUILDKIT=0 docker build \
        -t "${LCE_DEV_IMAGE}" \
        -f "${LCE_DEV_DOCKERFILE}" \
        "${LCE_DEV_BUILD_CONTEXT}" >>"${build_log}" 2>&1; then
        return 0
      fi
    fi

    echo "ERROR: Failed to build Docker image: ${LCE_DEV_IMAGE}" >&2
    echo "Build log: ${build_log}" >&2
    tail -n 80 "${build_log}" >&2 || true
    exit 1
  fi
}

start_lce() {
  local log_file="${LOG_DIR}/lce-bridge.log"
  if [[ "${LCE_FORCE_RESTART}" == "1" ]]; then
    stop_existing_lce
  fi

  ensure_cloak_key

  if [[ "${LCE_FORCE_LOCAL}" == "1" ]] && command -v mix >/dev/null 2>&1; then
    LCE_LOCAL=1
  elif [[ "${LCE_FORCE_DOCKER}" == "1" ]]; then
    LCE_LOCAL=0
  elif [[ "${LCE_PREFER_DOCKER}" == "1" ]] && command -v docker >/dev/null 2>&1; then
    LCE_LOCAL=0
  elif command -v mix >/dev/null 2>&1; then
    LCE_LOCAL=1
  else
    LCE_LOCAL=0
  fi

  if [[ "${LCE_LOCAL}" == "1" ]]; then
    LCE_LOCAL=1
    export LCE_CHILDREN_MODE="${LCE_CHILDREN_MODE:-on}"
    ensure_postgres
    (
	      cd "${LCE_DIR}/src/bridge"
	      # Explicit dirs make the bridge independent of where this script lives.
	      export LCE_ROOT_DIR="${WORK_DIR}"
	      if [[ -n "${ZEBRA_DIR}" ]]; then
	        export LCE_ZEBRA_DIR="${ZEBRA_DIR}"
	      fi
	      if [[ -n "${RFID_DIR}" ]]; then
	        export LCE_RFID_DIR="${RFID_DIR}"
	      fi
	      export CLOAK_KEY="${CLOAK_KEY}"
	      export MIX_ENV=dev
      mix local.hex --force
      mix local.rebar --force
      mix deps.get
      mix ecto.create || true
      mix ecto.migrate
      mix run --no-halt
    ) >"${log_file}" 2>&1 &
    LCE_PID=$!
    export LCE_PID
  else
    LCE_LOCAL=0
    export LCE_CHILDREN_MODE="${LCE_CHILDREN_MODE:-on}"
    start_lce_docker "${log_file}"
  fi
}

ensure_postgres() {
  if command -v pg_isready >/dev/null 2>&1; then
    if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
      return 0
    fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL is not running and Docker is not available." >&2
    exit 1
  fi
  if docker ps -q -f "name=^${LCE_POSTGRES_CONTAINER}$" | grep -q .; then
    return 0
  fi
  if docker ps -aq -f "name=^${LCE_POSTGRES_CONTAINER}$" | grep -q .; then
    docker start "${LCE_POSTGRES_CONTAINER}" >/dev/null
    return 0
  fi
  if ! docker network ls --format '{{.Name}}' | grep -q "^${LCE_DOCKER_NETWORK}\$"; then
    docker network create "${LCE_DOCKER_NETWORK}" >/dev/null
  fi
  docker run -d --name "${LCE_POSTGRES_CONTAINER}" --network "${LCE_DOCKER_NETWORK}" \
    -e POSTGRES_USER=titan -e POSTGRES_PASSWORD=titan_secret -e POSTGRES_DB=titan_bridge_dev \
    -p 5432:5432 --restart unless-stopped postgres:16-alpine >/dev/null
  for _ in $(seq 1 30); do
    if docker exec "${LCE_POSTGRES_CONTAINER}" pg_isready -U titan -d titan_bridge_dev >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.3
  done
  echo "ERROR: PostgreSQL container did not become ready." >&2
  exit 1
}

ensure_core_cache_postgres() {
  if command -v pg_isready >/dev/null 2>&1; then
    if pg_isready -h 127.0.0.1 -p "${CORE_PG_PORT}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "WARNING: Docker not available for core cache PostgreSQL." >&2
    return 0
  fi
  if docker ps -q -f "name=^${CORE_PG_CONTAINER}$" | grep -q .; then
    return 0
  fi
  if docker ps -aq -f "name=^${CORE_PG_CONTAINER}$" | grep -q .; then
    docker start "${CORE_PG_CONTAINER}" >/dev/null
    return 0
  fi
  if ! docker network ls --format '{{.Name}}' | grep -q "^${LCE_DOCKER_NETWORK}\$"; then
    docker network create "${LCE_DOCKER_NETWORK}" >/dev/null
  fi
  docker run -d --name "${CORE_PG_CONTAINER}" --network "${LCE_DOCKER_NETWORK}" \
    -e POSTGRES_USER="${CORE_PG_USER}" -e POSTGRES_PASSWORD="${CORE_PG_PASSWORD}" -e POSTGRES_DB="${CORE_PG_DB}" \
    -p "${CORE_PG_PORT}:5432" --restart unless-stopped postgres:16-alpine >/dev/null
  for _ in $(seq 1 30); do
    if docker exec "${CORE_PG_CONTAINER}" pg_isready -U "${CORE_PG_USER}" -d "${CORE_PG_DB}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.3
  done
  echo "WARNING: core cache PostgreSQL container did not become ready." >&2
}

start_lce_docker() {
  local log_file="$1"
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: mix not found and Docker is not available." >&2
    exit 1
  fi
  ensure_postgres
  ensure_lce_dev_image
  # Eski konteynerni BUTUNLAY o'chiramiz
  # 1) restart policy → no (Docker qayta yaratmasin)
  # 2) stop (graceful)
  # 3) rm -f (o'chirish)
  docker update --restart no "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1 || true
  docker stop "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1 || true
  # _build cache'ni faqat kod o'zgarganda tozalaymiz
  # Marker fayl oxirgi muvaffaqiyatli build vaqtini saqlaydi
  local build_marker="${LCE_BUILD_CACHE_DIR}/.last_build_ts"
  local source_dir="${LCE_DIR}/src/bridge/lib"
  local need_rebuild=0
  if [[ ! -f "${build_marker}" ]]; then
    need_rebuild=1
  elif [[ -d "${source_dir}" ]]; then
    # lib/ yoki config/ da build_marker'dan keyin o'zgargan fayl bormi?
    local newer
    newer="$(find "${source_dir}" "${LCE_DIR}/src/bridge/config" \
      -newer "${build_marker}" -name '*.ex' -o -name '*.exs' 2>/dev/null | head -1)"
    if [[ -n "${newer}" ]]; then
      need_rebuild=1
    fi
  fi
  if [[ "${need_rebuild}" -eq 1 && -d "${LCE_BUILD_CACHE_DIR}" ]]; then
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "Kod o'zgargan — _build tozalanmoqda..."
    fi
    docker run --rm -v "${LCE_BUILD_CACHE_DIR}:/cache" busybox rm -rf /cache/* 2>/dev/null \
      || rm -rf "${LCE_BUILD_CACHE_DIR}" 2>/dev/null || true
    mkdir -p "${LCE_BUILD_CACHE_DIR}"
  fi
  if ! docker network ls --format '{{.Name}}' | grep -q "^${LCE_DOCKER_NETWORK}\$"; then
    docker network create "${LCE_DOCKER_NETWORK}" >/dev/null
  fi
  mkdir -p "${LCE_MIX_CACHE_DIR}" "${LCE_BUILD_CACHE_DIR}" "${LCE_DEPS_CACHE_DIR}"
  free_port "${ZEBRA_WEB_PORT}"
  free_port "${RFID_WEB_PORT}"
  local -a docker_args=(
    run -d --name "${LCE_DOCKER_CONTAINER}" --network "${LCE_DOCKER_NETWORK}"
    --dns "${LCE_DOCKER_DNS_PRIMARY}"
    --dns "${LCE_DOCKER_DNS_SECONDARY}"
    -p "${LCE_PORT}:4000"
    -p "${ZEBRA_WEB_PORT}:${ZEBRA_WEB_PORT}"
    -p "${RFID_WEB_PORT}:${RFID_WEB_PORT}"
    -e DATABASE_URL="ecto://titan:titan_secret@${LCE_POSTGRES_CONTAINER}:5432/titan_bridge_dev"
    -e MIX_ENV=dev
    -e CLOAK_KEY="${CLOAK_KEY}"
    -e LCE_HOST_ALIAS="host.docker.internal"
    -e LCE_SIMULATE_DEVICES="${LCE_SIMULATE_DEVICES}"
    -e "LCE_CHILDREN_TARGET=${LCE_CHILDREN_TARGET:-all}"
    -e "LCE_CHILDREN_MODE=${LCE_CHILDREN_MODE:-on}"
    -v "${LCE_MIX_CACHE_DIR}:/root/.mix"
    -v "${LCE_DIR}/src/bridge:/app"
    -v "${LCE_BUILD_CACHE_DIR}:/app/_build"
    -v "${LCE_DEPS_CACHE_DIR}:/app/deps"
    -w /app
    --add-host=host.docker.internal:host-gateway
    --restart no
  )

  if [[ -n "${ZEBRA_DIR}" ]]; then
    docker_args+=( -e LCE_ZEBRA_DIR="/zebra_v1" -v "${ZEBRA_DIR}:/zebra_v1" )
  fi
  if [[ -n "${RFID_DIR}" ]]; then
    docker_args+=( -e LCE_RFID_DIR="/rfid" -v "${RFID_DIR}:/rfid" )
  fi

  docker "${docker_args[@]}" "${LCE_DEV_IMAGE}" \
      bash -lc "if ! ls /root/.mix/archives/hex-* >/dev/null 2>&1; then mix local.hex --force; fi \
        && if ! ls /root/.mix/elixir/*/rebar3 >/dev/null 2>&1; then mix local.rebar --force; fi \
        && mix deps.get \
        && (mix ecto.create || true) && mix ecto.migrate && mix run --no-halt" \
      >/dev/null 2>&1
  LCE_DOCKER=1
  LCE_CHILD_HOST="127.0.0.1"
  # Build marker — health tayyor bo'lganda yaratiladi (fonda)
  (
    wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" \
      && touch "${build_marker}"
  ) >/dev/null 2>&1 &
}

cleanup() {
  if [[ -n "${LCE_PID:-}" ]] && kill -0 "${LCE_PID}" >/dev/null 2>&1; then
    kill "${LCE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CORE_AGENT_PID:-}" ]] && kill -0 "${CORE_AGENT_PID}" >/dev/null 2>&1; then
    kill "${CORE_AGENT_PID}" >/dev/null 2>&1 || true
  fi
  if [[ "${CORE_AGENT_DOCKER}" -eq 1 && "${LCE_KEEP_DOCKER}" != "1" ]]; then
    docker rm -f "${CORE_AGENT_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ "${LCE_DOCKER}" -eq 1 && "${LCE_KEEP_DOCKER}" != "1" ]]; then
    docker rm -f "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -z "${LCE_CHILDREN_TARGET:-}" ]]; then
  if [[ -t 0 ]]; then
    echo "Select extension to start:"
    echo "  1) Zebra"
    echo "  2) RFID"
    read -r -p "Choice [1-2]: " choice
    case "${choice}" in
      2)
        LCE_CHILDREN_TARGET="rfid"
        ;;
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

# Validate required extension directories based on selected target.
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
if [[ "${need_zebra}" -eq 1 ]] && [[ -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" ]]; then
  missing_zebra=1
fi
if [[ "${need_rfid}" -eq 1 ]] && [[ -z "${RFID_DIR}" || ! -d "${RFID_DIR}" ]]; then
  missing_rfid=1
fi

if [[ "${LCE_AUTO_FETCH_CHILDREN}" == "1" ]] && [[ "${missing_zebra}" -eq 1 || "${missing_rfid}" -eq 1 ]]; then
  if [[ ! -f "${FETCH_CHILDREN_SCRIPT}" ]]; then
    echo "ERROR: Missing fetch script: ${FETCH_CHILDREN_SCRIPT}" >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to auto-download child repos (zebra/rfid)." >&2
    echo "Install git or clone the repos manually." >&2
    exit 1
  fi

  fetch_log="${LOG_DIR}/fetch_children.log"
  fetch_zebra=0
  fetch_rfid=0

  # If user overrides the directories explicitly, don't auto-clone elsewhere.
  if [[ "${missing_zebra}" -eq 1 ]] && [[ -z "${LCE_ZEBRA_HOST_DIR:-}" ]]; then
    fetch_zebra=1
  fi
  if [[ "${missing_rfid}" -eq 1 ]] && [[ -z "${LCE_RFID_HOST_DIR:-}" ]]; then
    fetch_rfid=1
  fi

  if [[ "${fetch_zebra}" -eq 1 || "${fetch_rfid}" -eq 1 ]]; then
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "Child repo'lar topilmadi — avtomatik yuklab olinmoqda..."
    fi

    if [[ "${LCE_QUIET}" == "1" ]]; then
      if ! LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA="${fetch_zebra}" LCE_FETCH_RFID="${fetch_rfid}" \
        bash "${FETCH_CHILDREN_SCRIPT}" >"${fetch_log}" 2>&1; then
        echo "ERROR: Failed to auto-download child repos." >&2
        echo "Log: ${fetch_log}" >&2
        tail -n 80 "${fetch_log}" >&2 || true
        exit 1
      fi
    else
      LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA="${fetch_zebra}" LCE_FETCH_RFID="${fetch_rfid}" \
        bash "${FETCH_CHILDREN_SCRIPT}"
    fi

    ZEBRA_DIR="$(detect_zebra_dir)"
    RFID_DIR="$(detect_rfid_dir)"
  fi
fi

# Final validation after optional auto-fetch.
if [[ "${need_zebra}" -eq 1 ]]; then
  if [[ -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" ]]; then
    echo "ERROR: zebra directory not found." >&2
    echo "Expected one of these directories (next to LCE/ or inside LCE/):" >&2
    echo "  - zebra_v1/" >&2
    echo "  - ERPNext_Zebra_stabil_enterprise_version/" >&2
    echo "Fix options:" >&2
    echo "  1) Run: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
    echo "  2) Or clone manually:" >&2
    echo "     git clone https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git" >&2
    echo "  3) Or set LCE_ZEBRA_HOST_DIR=/path/to/zebra" >&2
    exit 1
  fi
else
  ZEBRA_DIR=""
fi

if [[ "${need_rfid}" -eq 1 ]]; then
  if [[ -z "${RFID_DIR}" || ! -d "${RFID_DIR}" ]]; then
    echo "ERROR: rfid directory not found." >&2
    echo "Expected one of these directories (next to LCE/ or inside LCE/):" >&2
    echo "  - rfid/" >&2
    echo "  - ERPNext_UHFReader288_integration/" >&2
    echo "Fix options:" >&2
    echo "  1) Run: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
    echo "  2) Or clone manually:" >&2
    echo "     git clone https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git" >&2
    echo "  3) Or set LCE_RFID_HOST_DIR=/path/to/rfid" >&2
    exit 1
  fi
else
  RFID_DIR=""
fi

if [[ "${LCE_DRY_RUN}" == "1" ]]; then
  echo "DRY RUN"
  echo "LCE_DIR:   ${LCE_DIR}"
  echo "WORK_DIR:  ${WORK_DIR}"
  echo "TARGET:    ${LCE_CHILDREN_TARGET}"
  echo "ZEBRA_DIR: ${ZEBRA_DIR:-}"
  echo "RFID_DIR:  ${RFID_DIR:-}"
  exit 0
fi

LCE_TOKEN_FILE="${LCE_TOKEN_FILE:-${LCE_DIR}/.tg_token}"
SAVED_TOKEN=""
if [[ -f "${LCE_TOKEN_FILE}" ]]; then
  SAVED_TOKEN="$(cat "${LCE_TOKEN_FILE}" 2>/dev/null)"
  SAVED_TOKEN="$(trim_token "${SAVED_TOKEN}")"
fi

SAVED_VALID=0
if [[ -n "${SAVED_TOKEN}" ]] && valid_telegram_token "${SAVED_TOKEN}"; then
  SAVED_VALID=1
  if [[ "${LCE_QUIET}" != "1" ]]; then
    echo "Saqlangan token: $(mask_token "${SAVED_TOKEN}")"
  fi
elif [[ -n "${SAVED_TOKEN}" ]]; then
  echo "Saqlangan token yaroqsiz, yangisini kiriting."
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

export TG_TOKEN LCE_CHILDREN_TARGET
export LCE_ZEBRA_PORT="${ZEBRA_WEB_PORT}"
export LCE_RFID_PORT="${RFID_WEB_PORT}"
export LCE_ZEBRA_URL="http://${LCE_CHILD_HOST}:${ZEBRA_WEB_PORT}"
export LCE_RFID_URL="http://${LCE_CHILD_HOST}:${RFID_WEB_PORT}"

ZEBRA_URL="${LCE_ZEBRA_URL}"
RFID_URL="${LCE_RFID_URL}"
export ZEBRA_URL RFID_URL

# Hamma narsa parallel ishga tushadi
start_lce

# Config fonda yuboriladi — bridge tayyor bo'lganda
(
  wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" \
    && post_config "${TG_TOKEN}" "${ZEBRA_URL}" "${RFID_URL}"
) >/dev/null 2>&1 &
CONFIG_PID=$!

start_zebra_tui() {
  local zebra_dir="${ZEBRA_DIR}"

  # Docker ichida Zebra Web ishga tushayotganda hostdagi build bilan to'qnashmaslik uchun
  # avval no-build rejimida urinamiz.
  if [[ "${LCE_DOCKER}" -eq 1 ]]; then
    # Run TUI inside the already-running bridge container so host doesn't need .NET.
    if [[ "${LCE_ZEBRA_TUI_NO_BUILD}" == "1" ]]; then
      if docker exec -it "${LCE_DOCKER_CONTAINER}" bash -lc "cd /zebra_v1 && env CLI_NO_BUILD=1 ./cli.sh tui --url \"${LCE_ZEBRA_URL}\""; then
        return 0
      fi
      if [[ "${LCE_QUIET}" != "1" ]]; then
        echo "WARNING: Zebra TUI no-build rejimida ochilmadi, build bilan qayta urinish..." >&2
      fi
    fi

    # Build step (first run) can take time; show a spinner in quiet mode.
    if [[ "${LCE_QUIET}" == "1" ]]; then
      run_with_spinner "Zebra build" docker exec "${LCE_DOCKER_CONTAINER}" \
        bash -lc "cd /zebra_v1 && ./cli.sh version >/dev/null 2>&1"
    fi

    docker exec -it "${LCE_DOCKER_CONTAINER}" bash -lc "cd /zebra_v1 && ./cli.sh tui --url \"${LCE_ZEBRA_URL}\""
    return $?
  fi

  if [[ "${LCE_ZEBRA_TUI_NO_BUILD}" == "1" ]]; then
    if (cd "${zebra_dir}" && env CLI_NO_BUILD=1 ./cli.sh tui --url "${LCE_ZEBRA_URL}"); then
      return 0
    fi
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "WARNING: Zebra TUI no-build rejimida ochilmadi, build bilan qayta urinish..." >&2
    fi
  fi

  # Build step (first run) can take time; show a spinner in quiet mode.
  if [[ "${LCE_QUIET}" == "1" ]]; then
    run_with_spinner "Zebra build" bash -lc "cd \"${zebra_dir}\" && ./cli.sh version >/dev/null 2>&1"
  fi
  (cd "${zebra_dir}" && ./cli.sh tui --url "${LCE_ZEBRA_URL}")
}

start_core_agent() {
  local agent_dir="${LCE_DIR}/src/core_agent"
  if [[ ! -d "${agent_dir}" ]]; then
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "WARNING: core_agent directory missing: ${agent_dir}" >&2
    fi
    return 0
  fi
  ensure_core_cache_postgres

  # Host endpoints (used by local `dotnet run`)
  local host_ws_url="ws://127.0.0.1:${LCE_PORT}/ws/core"
  local host_api_base="http://127.0.0.1:${LCE_PORT}"
  local host_pg_url="postgres://${CORE_PG_USER}:${CORE_PG_PASSWORD}@127.0.0.1:${CORE_PG_PORT}/${CORE_PG_DB}"
  local host_zebra_url="http://127.0.0.1:${ZEBRA_WEB_PORT}"
  local host_rfid_url="http://127.0.0.1:${RFID_WEB_PORT}"

  # Container endpoints (used when core-agent runs in Docker)
  local docker_ws_url
  local docker_api_base
  local docker_zebra_url
  local docker_rfid_url
  local docker_pg_url="postgres://${CORE_PG_USER}:${CORE_PG_PASSWORD}@${CORE_PG_CONTAINER}:5432/${CORE_PG_DB}"

  if [[ "${LCE_DOCKER}" -eq 1 ]]; then
    docker_ws_url="ws://${LCE_DOCKER_CONTAINER}:4000/ws/core"
    docker_api_base="http://${LCE_DOCKER_CONTAINER}:4000"
    docker_zebra_url="http://${LCE_DOCKER_CONTAINER}:${ZEBRA_WEB_PORT}"
    docker_rfid_url="http://${LCE_DOCKER_CONTAINER}:${RFID_WEB_PORT}"
  else
    docker_ws_url="ws://host.docker.internal:${LCE_PORT}/ws/core"
    docker_api_base="http://host.docker.internal:${LCE_PORT}"
    docker_zebra_url="http://host.docker.internal:${ZEBRA_WEB_PORT}"
    docker_rfid_url="http://host.docker.internal:${RFID_WEB_PORT}"
  fi

  if command -v dotnet >/dev/null 2>&1; then
    export CORE_WS_URL="${host_ws_url}"
    export CORE_DEVICE_ID="${CORE_DEVICE_ID:-CORE-01}"
    export LCE_API_BASE="${host_api_base}"
    export LCE_CORE_TOKEN="${LCE_CORE_TOKEN:-}"
    export CORE_PG_URL="${host_pg_url}"
    export CORE_PG_SCHEMA="${CORE_PG_SCHEMA:-core_cache}"
    export ZEBRA_URL="${host_zebra_url}"
    export RFID_URL="${host_rfid_url}"

    (cd "${agent_dir}" && dotnet run) >"${CORE_AGENT_LOG}" 2>&1 &
    CORE_AGENT_PID=$!
    CORE_AGENT_DOCKER=0
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "WARNING: dotnet not found, core-agent not started." >&2
    fi
    return 0
  fi

  # Docker fallback: use the same pinned dev image (includes .NET 10).
  ensure_lce_dev_image

  docker rm -f "${CORE_AGENT_CONTAINER}" >/dev/null 2>&1 || true

  docker run -d --name "${CORE_AGENT_CONTAINER}" --network "${LCE_DOCKER_NETWORK}" \
    --add-host=host.docker.internal:host-gateway \
    -e CORE_WS_URL="${docker_ws_url}" \
    -e CORE_DEVICE_ID="${CORE_DEVICE_ID:-CORE-01}" \
    -e LCE_API_BASE="${docker_api_base}" \
    -e LCE_CORE_TOKEN="${LCE_CORE_TOKEN:-}" \
    -e CORE_PG_URL="${docker_pg_url}" \
    -e CORE_PG_SCHEMA="${CORE_PG_SCHEMA:-core_cache}" \
    -e ZEBRA_URL="${docker_zebra_url}" \
    -e RFID_URL="${docker_rfid_url}" \
    -v "${agent_dir}:/agent" \
    -w /agent \
    "${LCE_DEV_IMAGE}" \
    bash -lc "dotnet run" >/dev/null 2>&1

  CORE_AGENT_DOCKER=1
}

start_core_agent

# Zebra tanlangan va TUI mavjud bo'lsa — TUI ochiladi (blocking)
# Aks holda — banner + wait
SHOW_BANNER=1
if [[ "${LCE_SHOW_ZEBRA_TUI:-0}" == "1" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
  # LCE va Zebra xizmatlari ishga tushayotganini ko'rsatish (quiet mode).
  if [[ "${LCE_QUIET}" == "1" ]]; then
    wait_for_url_with_spinner "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" "LCE ishga tushmoqda" || true
    wait_for_url_with_spinner "${LCE_ZEBRA_URL}/api/v1/health" 240 0.25 "Zebra ishga tushmoqda" || true
	  else
	    wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" >/dev/null 2>&1 || true
	    wait_for_url "${LCE_ZEBRA_URL}/api/v1/health" 240 0.25 >/dev/null 2>&1 || true
	  fi

  if start_zebra_tui; then
    SHOW_BANNER=0
  else
    if [[ "${LCE_QUIET}" != "1" ]]; then
      echo "WARNING: Zebra TUI ishga tushmadi. Log: ${ZEBRA_DIR}/logs/cli-build.log" >&2
    fi
  fi
fi

if [[ "${SHOW_BANNER}" == "1" ]]; then
  if [[ "${LCE_QUIET}" == "1" ]]; then
    wait_for_url_with_spinner "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" "LCE ishga tushmoqda" || true
  else
    wait_for_url "http://127.0.0.1:${LCE_PORT}/api/health" "${LCE_WAIT_ATTEMPTS}" "${LCE_WAIT_DELAY}" >/dev/null 2>&1 || true
  fi

  OPEN_URL="http://127.0.0.1:${LCE_PORT}/api/status"
  if [[ "${LCE_CHILDREN_TARGET}" == *"rfid"* ]] || [[ "${LCE_CHILDREN_TARGET}" == "all" ]]; then
    OPEN_URL="http://127.0.0.1:${RFID_WEB_PORT}/"
  elif [[ "${LCE_CHILDREN_TARGET}" == *"zebra"* ]]; then
    OPEN_URL="http://127.0.0.1:${ZEBRA_WEB_PORT}/"
  fi
  echo "ishga tushdi ${OPEN_URL} manashu pathni oching"

  if [[ "${LCE_DOCKER}" -eq 1 ]]; then
    docker wait "${LCE_DOCKER_CONTAINER}" >/dev/null 2>&1
  elif [[ -n "${LCE_PID:-}" ]]; then
    wait "${LCE_PID}"
  else
    sleep infinity
  fi
fi
