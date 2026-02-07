#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="titan"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dotnet() {
    if ! command -v dotnet &> /dev/null; then
        log_error "dotnet is not installed"
        exit 1
    fi
    DOTNET_VERSION=$(dotnet --version)
    if [[ ! $DOTNET_VERSION == 10.* ]]; then
        log_warn "dotnet version is $DOTNET_VERSION, expected 10.x"
    fi
}

build() {
    log_info "Building Titan.Core..."
    cd "$SCRIPT_DIR"
    dotnet restore src/Titan.Host/Titan.Host.csproj
    dotnet build src/Titan.Host/Titan.Host.csproj -c Release
    log_info "Build completed"
}

dev() {
    log_info "Running in development mode..."
    cd "$SCRIPT_DIR/src/Titan.Host"
    dotnet run
}

docker_run() {
    log_info "Running with Docker Compose..."
    cd "$SCRIPT_DIR"
    docker compose up --build
}

migrate() {
    log_info "Running database migrations..."
    cd "$SCRIPT_DIR/src/Titan.Host"
    dotnet ef database update
}

add_migration() {
    if [ -z "$1" ]; then
        log_error "Migration name required"
        exit 1
    fi
    log_info "Creating migration: $1"
    cd "$SCRIPT_DIR/src/Titan.Host"
    dotnet ef migrations add "$1" --project ../Titan.Infrastructure/
}

clean() {
    log_info "Cleaning build artifacts..."
    cd "$SCRIPT_DIR"
    find . -type d -name "bin" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name "obj" -exec rm -rf {} + 2>/dev/null || true
    log_info "Clean completed"
}

show_help() {
    echo "Titan.Core Build Script"
    echo ""
    echo "Usage: ./run.sh [command]"
    echo ""
    echo "Commands:"
    echo "  build          Build the project"
    echo "  dev            Run in development mode"
    echo "  docker         Run with Docker Compose"
    echo "  migrate        Run database migrations"
    echo "  add-migration  Create new migration (requires name)"
    echo "  clean          Clean build artifacts"
    echo "  help           Show this help"
}

case "${1:-help}" in
    build)      check_dotnet; build ;;
    dev)        check_dotnet; dev ;;
    docker)     docker_run ;;
    migrate)    check_dotnet; migrate ;;
    add-migration) check_dotnet; add_migration "$2" ;;
    clean)      clean ;;
    help|--help|-h) show_help ;;
    *)          log_error "Unknown command: $1"; show_help; exit 1 ;;
esac
