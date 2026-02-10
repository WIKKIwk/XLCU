#!/usr/bin/env bash
set -euo pipefail

# Bootstrap system dependencies for this repo (Ubuntu/Debian + Arch).
# This script installs packages (requires sudo/root).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: bash scripts/bootstrap.sh [options]

Installs system prerequisites for running this repo on:
  - Ubuntu/Debian (apt)
  - Arch Linux (pacman)

Options:
  --check        Only check required commands (no install). Exit 0 if OK, 1 if missing.
  --dry-run      Print commands instead of running them.
  -y, --yes      Do not ask for confirmation (still may prompt for sudo password).
  -h, --help     Show this help.

Notes:
  - Docker installation requires root privileges.
  - After adding your user to the "docker" group, you must log out/in (or run: newgrp docker).
EOF
}

CHECK_ONLY=0
DRY_RUN=0
ASSUME_YES=0

for arg in "${@:-}"; do
  case "${arg}" in
    --check) CHECK_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: Unknown argument: ${arg}" >&2
      echo >&2
      usage >&2
      exit 2
      ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %q' "$1"
    shift || true
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  "$@"
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    run "$@"
    return 0
  fi
  if ! have sudo; then
    echo "ERROR: sudo not found; run this script as root." >&2
    exit 1
  fi
  run sudo "$@"
}

detect_os_family() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  local id="${ID:-}"
  local like="${ID_LIKE:-}"

  case "${id}" in
    ubuntu|debian) echo "debian"; return 0 ;;
    arch) echo "arch"; return 0 ;;
  esac

  if [[ "${like}" == *debian* ]]; then
    echo "debian"
    return 0
  fi
  if [[ "${like}" == *arch* ]]; then
    echo "arch"
    return 0
  fi

  echo "unknown"
}

confirm_or_exit() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "ERROR: non-interactive shell. Re-run with --yes." >&2
    exit 1
  fi

  echo "Repo: ${REPO_DIR}"
  echo "This will install system packages (needs sudo)."
  read -r -p "Continue? [y/N]: " ans
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

check_required() {
  local missing=0

  for cmd in git curl docker; do
    if ! have "${cmd}"; then
      echo "MISSING: ${cmd}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "MISSING: docker daemon is not running (docker info failed)"
    return 1
  fi

  echo "OK: git/curl/docker are available and docker daemon is running."
  return 0
}

start_docker_service() {
  if have systemctl; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || as_root systemctl start docker >/dev/null 2>&1 || true
    return 0
  fi

  if have service; then
    as_root service docker start >/dev/null 2>&1 || true
    return 0
  fi
}

ensure_docker_group() {
  local u="${SUDO_USER:-${USER}}"

  if have getent; then
    if ! getent group docker >/dev/null 2>&1; then
      as_root groupadd docker >/dev/null 2>&1 || true
    fi
  fi

  if id -nG "${u}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    return 0
  fi

  as_root usermod -aG docker "${u}" >/dev/null 2>&1 || true

  echo "NOTE: user '${u}' added to docker group. Log out/in (or run: newgrp docker)."
}

install_debian() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -y

  # Core tools used by scripts.
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl lsof make

  # Optional (nice-to-have).
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends screen >/dev/null 2>&1 || true

  # Docker (from distro repo). This is the most predictable for automation.
  if ! dpkg -s docker.io >/dev/null 2>&1; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io
  fi

  # Compose plugin is optional for this repo; install if available.
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-compose-plugin >/dev/null 2>&1 || true

  start_docker_service
  ensure_docker_group
}

install_arch() {
  # Keep arch consistent (avoid partial upgrades).
  as_root pacman -Syu --noconfirm --needed \
    ca-certificates curl git openssl lsof make screen docker docker-compose

  start_docker_service
  ensure_docker_group
}

main() {
  local os_family
  os_family="$(detect_os_family)"
  if [[ "${os_family}" == "unknown" ]]; then
    echo "ERROR: Unsupported OS. Supported: Ubuntu/Debian and Arch." >&2
    exit 1
  fi

  if [[ "${CHECK_ONLY}" == "1" ]]; then
    check_required
    exit $?
  fi

  confirm_or_exit

  case "${os_family}" in
    debian) install_debian ;;
    arch) install_arch ;;
  esac

  echo "Bootstrap: OK"
}

main "$@"

