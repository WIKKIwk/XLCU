#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"

OUT_BASE="${LCE_SUPPORT_DIR:-${WORK_DIR}/support}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE_DIR="${OUT_BASE}/xlcu-support-${STAMP}"
ARCHIVE="${BUNDLE_DIR}.tar.gz"

mkdir -p "${BUNDLE_DIR}"

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose -f "${LCE_DIR}/docker-compose.run.yml" -p lce)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose -f "${LCE_DIR}/docker-compose.run.yml" -p lce)
    return 0
  fi
  COMPOSE_CMD=()
  return 1
}

{
  echo "timestamp_utc=${STAMP}"
  echo "cwd=${LCE_DIR}"
  echo "work_dir=${WORK_DIR}"
  echo "user=${USER:-unknown}"
  echo "host=$(hostname 2>/dev/null || true)"
  echo "uname=$(uname -a 2>/dev/null || true)"
} > "${BUNDLE_DIR}/meta.txt"

{
  git -C "${LCE_DIR}" rev-parse HEAD 2>/dev/null || true
  git -C "${LCE_DIR}" status --short 2>/dev/null || true
  git -C "${LCE_DIR}" log --oneline -n 20 2>/dev/null || true
} > "${BUNDLE_DIR}/git.txt"

{
  bash "${LCE_DIR}/scripts/doctor.sh"
} > "${BUNDLE_DIR}/doctor.txt" 2>&1 || true

if command -v docker >/dev/null 2>&1; then
  {
    docker version 2>/dev/null || true
    docker info 2>/dev/null || true
  } > "${BUNDLE_DIR}/docker.txt"

  docker ps -a > "${BUNDLE_DIR}/docker-ps.txt" 2>&1 || true
  docker images > "${BUNDLE_DIR}/docker-images.txt" 2>&1 || true

  if detect_compose; then
    "${COMPOSE_CMD[@]}" ps -a > "${BUNDLE_DIR}/compose-ps.txt" 2>&1 || true
    "${COMPOSE_CMD[@]}" logs --no-color > "${BUNDLE_DIR}/compose-logs.txt" 2>&1 || true
    "${COMPOSE_CMD[@]}" config > "${BUNDLE_DIR}/compose-config.txt" 2>&1 || true
  fi
fi

if [[ -d "${WORK_DIR}/logs" ]]; then
  mkdir -p "${BUNDLE_DIR}/logs"
  cp -a "${WORK_DIR}/logs/." "${BUNDLE_DIR}/logs/" 2>/dev/null || true
fi

tar -czf "${ARCHIVE}" -C "${OUT_BASE}" "$(basename -- "${BUNDLE_DIR}")"
echo "Support bundle created: ${ARCHIVE}"
