#!/usr/bin/env bash
set -euo pipefail

# Clone/update the child repos (zebra + rfid) into the expected directories.
# This keeps `make run` working without extra env vars on fresh machines.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -d "${LCE_DIR}/../zebra_v1" || -d "${LCE_DIR}/../ERPNext_Zebra_stabil_enterprise_version" || -d "${LCE_DIR}/../rfid" || -d "${LCE_DIR}/../ERPNext_UHFReader288_integration" ]]; then
  WORK_DIR="$(cd -- "${LCE_DIR}/.." && pwd)"
else
  WORK_DIR="${LCE_DIR}"
fi
WORK_DIR="${LCE_WORK_DIR:-${WORK_DIR}}"

ZEBRA_REPO_URL="${ZEBRA_REPO_URL:-https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git}"
RFID_REPO_URL="${RFID_REPO_URL:-https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git}"

# Destination dirs:
# - Prefer existing directories if present (avoid accidental duplicate clones).
# - Otherwise default to the GitHub repo name (what `git clone URL` creates).
default_zebra_dir="${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
if [[ -d "${WORK_DIR}/zebra_v1/.git" ]]; then
  default_zebra_dir="${WORK_DIR}/zebra_v1"
elif [[ -d "${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version/.git" ]]; then
  default_zebra_dir="${WORK_DIR}/ERPNext_Zebra_stabil_enterprise_version"
fi
ZEBRA_DIR="${ZEBRA_DIR:-${default_zebra_dir}}"

default_rfid_dir="${WORK_DIR}/ERPNext_UHFReader288_integration"
if [[ -d "${WORK_DIR}/rfid/.git" ]]; then
  default_rfid_dir="${WORK_DIR}/rfid"
elif [[ -d "${WORK_DIR}/ERPNext_UHFReader288_integration/.git" ]]; then
  default_rfid_dir="${WORK_DIR}/ERPNext_UHFReader288_integration"
fi
RFID_DIR="${RFID_DIR:-${default_rfid_dir}}"

ZEBRA_REF="${ZEBRA_REF:-main}"
RFID_REF="${RFID_REF:-main}"

FETCH_ZEBRA="${LCE_FETCH_ZEBRA:-1}"
FETCH_RFID="${LCE_FETCH_RFID:-1}"

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required." >&2
    exit 1
  fi
}

clone_or_update() {
  local name="$1"
  local url="$2"
  local dir="$3"
  local ref="$4"

  if [[ -d "${dir}/.git" ]]; then
    echo "${name}: updating ${dir}"
    git -C "${dir}" fetch --prune origin
    # Prefer the requested ref; fall back to current branch if ref doesn't exist.
    if git -C "${dir}" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
      git -C "${dir}" checkout -q "${ref}" 2>/dev/null || true
      git -C "${dir}" reset --hard "origin/${ref}" >/dev/null
    else
      # If the repo doesn't have that branch, just fast-forward the current branch.
      git -C "${dir}" pull --ff-only >/dev/null
    fi
    return 0
  fi

  if [[ -e "${dir}" ]]; then
    echo "ERROR: ${name} path exists but is not a git repo: ${dir}" >&2
    exit 1
  fi

  echo "${name}: cloning into ${dir}"
  git clone --depth 1 --branch "${ref}" "${url}" "${dir}" >/dev/null 2>&1 || {
    # Some repos may not have the requested branch (e.g. older master-only). Retry without branch pin.
    rm -rf "${dir}" 2>/dev/null || true
    git clone --depth 1 "${url}" "${dir}" >/dev/null
  }
}

require_git

echo "WORK_DIR:  ${WORK_DIR}"
echo "ZEBRA_DIR: ${ZEBRA_DIR}"
echo "RFID_DIR:  ${RFID_DIR}"
echo

if [[ "${FETCH_ZEBRA}" == "1" ]]; then
  clone_or_update "Zebra" "${ZEBRA_REPO_URL}" "${ZEBRA_DIR}" "${ZEBRA_REF}"
fi
if [[ "${FETCH_RFID}" == "1" ]]; then
  clone_or_update "RFID" "${RFID_REPO_URL}" "${RFID_DIR}" "${RFID_REF}"
fi

echo
echo "OK: children repos are present."
