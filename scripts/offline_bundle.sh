#!/usr/bin/env bash
set -euo pipefail

# Create an offline bundle that can be copied to factory PCs / Raspberry Pi.
# The bundle contains:
# - Prebuilt Docker images (bridge + postgres) as a compressed docker-save archive
# - Child app snapshots (rfid/zebra) without VCS metadata and local secrets
#
# Usage:
#   bash scripts/offline_bundle.sh [rfid|zebra|all]
#
# Output:
#   ./offline/xlcu-offline-<target>-<timestamp>.tar.gz

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"

have() { command -v "$1" >/dev/null 2>&1; }

trim() {
  local s="${1-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

derive_ghcr_image() {
  # ghcr.io/<owner>/xlcu-bridge-dev:<target> derived from git origin.
  if ! have git; then
    return 1
  fi

  local remote=""
  remote="$(git -C "${LCE_DIR}" remote get-url origin 2>/dev/null || true)"
  remote="$(trim "${remote}")"
  remote="${remote%/}"
  if [[ -z "${remote}" ]]; then
    return 1
  fi

  local owner=""
  if [[ "${remote}" =~ github\.com[:/]([^/]+)/ ]]; then
    owner="${BASH_REMATCH[1]}"
  fi
  owner="$(printf '%s' "${owner}" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${owner}" ]]; then
    return 1
  fi

  if [[ ! "${owner}" =~ ^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$ ]]; then
    return 1
  fi

  printf 'ghcr.io/%s/xlcu-bridge-dev:%s' "${owner}" "${LCE_BRIDGE_IMAGE_TARGET}"
}

detect_zebra_dir() {
  if [[ -d "${WORK_DIR}/zebra_v1" && -f "${WORK_DIR}/zebra_v1/run.sh" ]]; then
    printf '%s' "${WORK_DIR}/zebra_v1"
    return 0
  fi
  if [[ -d "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version" && -f "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version/run.sh" ]]; then
    printf '%s' "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
    return 0
  fi
  if [[ -d "${LCE_DIR}/zebra_v1" && -f "${LCE_DIR}/zebra_v1/run.sh" ]]; then
    printf '%s' "${LCE_DIR}/zebra_v1"
    return 0
  fi
  if [[ -d "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version" && -f "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version/run.sh" ]]; then
    printf '%s' "${LCE_DIR}/ERPNext_Zebra_stabil_enterprise_version"
    return 0
  fi
  printf '%s' ""
}

detect_rfid_dir() {
  if [[ -d "${WORK_DIR}/rfid" && -f "${WORK_DIR}/rfid/start-web.sh" ]]; then
    printf '%s' "${WORK_DIR}/rfid"
    return 0
  fi
  if [[ -d "${WORK_DIR}/ERPNext_UHFReader288_integration" && -f "${WORK_DIR}/ERPNext_UHFReader288_integration/start-web.sh" ]]; then
    printf '%s' "${WORK_DIR}/ERPNext_UHFReader288_integration"
    return 0
  fi
  if [[ -d "${LCE_DIR}/rfid" && -f "${LCE_DIR}/rfid/start-web.sh" ]]; then
    printf '%s' "${LCE_DIR}/rfid"
    return 0
  fi
  if [[ -d "${LCE_DIR}/ERPNext_UHFReader288_integration" && -f "${LCE_DIR}/ERPNext_UHFReader288_integration/start-web.sh" ]]; then
    printf '%s' "${LCE_DIR}/ERPNext_UHFReader288_integration"
    return 0
  fi
  printf '%s' ""
}

copy_dir_snapshot() {
  local src_dir="$1"
  local dest_parent="$2"
  local name=""

  if [[ -z "${src_dir}" || ! -d "${src_dir}" ]]; then
    return 0
  fi

  name="$(basename -- "${src_dir}")"
  mkdir -p "${dest_parent}"

  # Copy via tar to support excludes without requiring rsync.
  # Exclude VCS metadata + logs + local secrets/config.
  (
    cd -- "$(dirname -- "${src_dir}")"
    tar -cf - \
      --exclude-vcs \
      --exclude="${name}/logs" \
      --exclude="${name}/logs/*" \
      --exclude="${name}/**/logs" \
      --exclude="${name}/**/logs/*" \
      --exclude="${name}/.dotnet" \
      --exclude="${name}/.dotnet/*" \
      --exclude="${name}/**/.dotnet" \
      --exclude="${name}/**/.dotnet/*" \
      --exclude="${name}/Demo/web-localhost/server/local-config.json" \
      --exclude="${name}/**/local-config.json" \
      "${name}"
  ) | tar -C "${dest_parent}" -xf -
}

TARGET="${1:-${LCE_CHILDREN_TARGET:-rfid}}"
TARGET="$(trim "${TARGET}")"
TARGET="${TARGET,,}"
case "${TARGET}" in
  rfid|zebra|all) ;;
  *)
    echo "ERROR: invalid target: ${TARGET} (expected: rfid | zebra | all)" >&2
    exit 1
    ;;
esac

need_zebra=0
need_rfid=0
if [[ "${TARGET}" == "all" || "${TARGET}" == *"zebra"* ]]; then
  need_zebra=1
fi
if [[ "${TARGET}" == "all" || "${TARGET}" == *"rfid"* ]]; then
  need_rfid=1
fi

LCE_BRIDGE_IMAGE_TARGET="bridge-all"
case "${TARGET}" in
  zebra) LCE_BRIDGE_IMAGE_TARGET="bridge-zebra" ;;
  rfid) LCE_BRIDGE_IMAGE_TARGET="bridge-rfid" ;;
  *) LCE_BRIDGE_IMAGE_TARGET="bridge-all" ;;
esac

LCE_DEV_IMAGE="${LCE_DEV_IMAGE:-}"
if [[ -z "${LCE_DEV_IMAGE}" ]]; then
  LCE_DEV_IMAGE="$(derive_ghcr_image 2>/dev/null || true)"
fi
LCE_DEV_IMAGE="$(trim "${LCE_DEV_IMAGE}")"
if [[ -z "${LCE_DEV_IMAGE}" ]]; then
  echo "ERROR: cannot derive GHCR image from git origin." >&2
  echo "TIP: set LCE_DEV_IMAGE explicitly, e.g.:" >&2
  echo "  LCE_DEV_IMAGE=ghcr.io/<owner>/xlcu-bridge-dev:${LCE_BRIDGE_IMAGE_TARGET} bash scripts/offline_bundle.sh ${TARGET}" >&2
  exit 1
fi
if [[ "${LCE_DEV_IMAGE}" == *"://"* ]]; then
  echo "ERROR: invalid Docker image reference (URL ko'rinishida): ${LCE_DEV_IMAGE}" >&2
  exit 1
fi

if ! have docker; then
  echo "ERROR: docker is required." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not available (docker info failed)." >&2
  exit 1
fi

ZEBRA_DIR="$(detect_zebra_dir)"
RFID_DIR="$(detect_rfid_dir)"

if [[ "${need_zebra}" -eq 1 && ( -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" ) ]]; then
  echo "Fetching zebra child repo..."
  LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA=1 LCE_FETCH_RFID=0 bash "${SCRIPT_DIR}/fetch_children.sh"
  ZEBRA_DIR="$(detect_zebra_dir)"
fi
if [[ "${need_rfid}" -eq 1 && ( -z "${RFID_DIR}" || ! -d "${RFID_DIR}" ) ]]; then
  echo "Fetching rfid child repo..."
  LCE_WORK_DIR="${WORK_DIR}" LCE_FETCH_ZEBRA=0 LCE_FETCH_RFID=1 bash "${SCRIPT_DIR}/fetch_children.sh"
  RFID_DIR="$(detect_rfid_dir)"
fi

if [[ "${need_zebra}" -eq 1 && ( -z "${ZEBRA_DIR}" || ! -d "${ZEBRA_DIR}" ) ]]; then
  echo "ERROR: zebra child repo not found." >&2
  exit 1
fi
if [[ "${need_rfid}" -eq 1 && ( -z "${RFID_DIR}" || ! -d "${RFID_DIR}" ) ]]; then
  echo "ERROR: rfid child repo not found." >&2
  exit 1
fi

IMAGES=("${LCE_DEV_IMAGE}" "postgres:16-alpine")

echo "Offline bundle target: ${TARGET}"
echo "Bridge image: ${LCE_DEV_IMAGE}"
echo

for img in "${IMAGES[@]}"; do
  if ! docker image inspect "${img}" >/dev/null 2>&1; then
    echo "Pull: ${img}"
    docker pull "${img}"
  else
    echo "OK (cached): ${img}"
  fi
done

OUT_BASE="${OFFLINE_OUT_DIR:-${WORK_DIR}/offline}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE_DIR="${OUT_BASE}/xlcu-offline-${TARGET}-${STAMP}"
ARCHIVE="${BUNDLE_DIR}.tar.gz"

mkdir -p "${BUNDLE_DIR}/offline"

echo
echo "Saving Docker images -> offline/images.tar.gz (this can take a while)..."
docker save "${IMAGES[@]}" | gzip -c > "${BUNDLE_DIR}/offline/images.tar.gz"

if [[ "${need_rfid}" -eq 1 ]]; then
  echo "Snapshot: rfid child -> $(basename -- "${RFID_DIR}")"
  copy_dir_snapshot "${RFID_DIR}" "${BUNDLE_DIR}"
fi
if [[ "${need_zebra}" -eq 1 ]]; then
  echo "Snapshot: zebra child -> $(basename -- "${ZEBRA_DIR}")"
  copy_dir_snapshot "${ZEBRA_DIR}" "${BUNDLE_DIR}"
fi

cat > "${BUNDLE_DIR}/offline/INSTALL.txt" <<EOF
Offline install:

1) Copy ${ARCHIVE} to the target machine
2) Extract:
   tar -xzf $(basename -- "${ARCHIVE}")
3) Install into an existing XLCU repo directory:
   bash $(basename -- "${BUNDLE_DIR}")/offline/install.sh /path/to/XLCU
4) Run:
   cd /path/to/XLCU && make run
EOF

cat > "${BUNDLE_DIR}/offline/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

XLCU_DIR="${1:-}"
if [[ -z "${XLCU_DIR}" ]]; then
  echo "Usage: bash offline/install.sh /path/to/XLCU" >&2
  exit 2
fi
XLCU_DIR="$(cd -- "${XLCU_DIR}" && pwd)"

if [[ ! -f "${XLCU_DIR}/Makefile" ]]; then
  echo "ERROR: target directory does not look like XLCU repo: ${XLCU_DIR}" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not available (docker info failed)." >&2
  exit 1
fi

IMG_ARCHIVE="${BUNDLE_DIR}/offline/images.tar.gz"
if [[ ! -f "${IMG_ARCHIVE}" ]]; then
  echo "ERROR: missing images archive: ${IMG_ARCHIVE}" >&2
  exit 1
fi

echo "Loading Docker images..."
gzip -dc "${IMG_ARCHIVE}" | docker load
echo "OK: images loaded."

copy_if_missing() {
  local name="$1"
  if [[ -d "${BUNDLE_DIR}/${name}" && ! -d "${XLCU_DIR}/${name}" ]]; then
    echo "Installing child: ${name}"
    tar -C "${BUNDLE_DIR}" -cf - "${name}" | tar -C "${XLCU_DIR}" -xf -
  fi
}

copy_if_missing "ERPNext_UHFReader288_integration"
copy_if_missing "ERPNext_Zebra_stabil_enterprise_version"

echo "OK: offline install completed."
echo "Next: cd \"${XLCU_DIR}\" && make run"
SH
chmod +x "${BUNDLE_DIR}/offline/install.sh"

mkdir -p "${OUT_BASE}"
tar -czf "${ARCHIVE}" -C "${OUT_BASE}" "$(basename -- "${BUNDLE_DIR}")"

echo
echo "Offline bundle created:"
echo "${ARCHIVE}"
