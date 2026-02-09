#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FETCH_CHILDREN_SCRIPT="${SCRIPT_DIR}/fetch_children.sh"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"

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
  echo "Run: bash \"${FETCH_CHILDREN_SCRIPT}\"" >&2
  exit 1
fi

if ! bash -n "${LCE_DIR}/scripts/run_extensions.sh"; then
  echo "ERROR: scripts/run_extensions.sh has a syntax error." >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "Docker: OK"
  else
    echo "ERROR: Docker is installed but the daemon is not running (docker info failed)." >&2
    exit 1
  fi
else
  echo "WARNING: Docker not found. This will fall back to local 'mix' if available." >&2
  if ! command -v mix >/dev/null 2>&1; then
    echo "ERROR: Neither Docker nor mix are available. Install Docker (recommended) or Elixir/Mix." >&2
    exit 1
  fi
fi

DOCKERFILE_DEV="${LCE_DEV_DOCKERFILE:-${LCE_DIR}/src/bridge/Dockerfile.dev}"
if [[ -f "${DOCKERFILE_DEV}" ]]; then
  echo "Dockerfile.dev: OK"
else
  echo "ERROR: Missing ${DOCKERFILE_DEV}" >&2
  exit 1
fi

echo "Doctor: OK"
