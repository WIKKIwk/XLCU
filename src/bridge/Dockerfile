# ============================================
# TITAN BRIDGE - Docker & Deployment
# ============================================
# File: titan_bridge/Dockerfile
# ============================================
# Build stage
FROM hexpm/elixir:1.16.2-erlang-26.2.5-debian-bookworm-20240513-slim AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV=prod

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before compile
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# Runtime stage
FROM debian:bookworm-slim AS app

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app

RUN chown nobody:nogroup /app

# Set runner ENV
ENV MIX_ENV=prod

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:nogroup /app/_build/prod/rel/titan_bridge ./

USER nobody

# If using an environment that doesn't require secrets at build time
# you can provide them at runtime. Otherwise, use build args.
ENV HOME=/app

CMD ["bin/titan_bridge", "start"]

# ============================================
# File: titan_bridge/docker-compose.yml
# ============================================
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: titan-bridge-db
    environment:
      POSTGRES_USER: titan
      POSTGRES_PASSWORD: titan_secret
      POSTGRES_DB: titan_bridge_prod
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    networks:
      - titan-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U titan -d titan_bridge_prod"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: titan-bridge-redis
    volumes:
      - redis_data:/data
    networks:
      - titan-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  titan-bridge:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: titan-bridge-app
    environment:
      # Database
      DATABASE_URL: ecto://titan:titan_secret@postgres/titan_bridge_prod
      POOL_SIZE: 10
      
      # Phoenix
      PHX_HOST: localhost
      PORT: 4000
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      
      # Security
      SESSION_ENCRYPTION_KEY: ${SESSION_ENCRYPTION_KEY}
      TITAN_API_TOKEN: ${TITAN_API_TOKEN}
      
      # Telegram
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
      TELEGRAM_BOT_USERNAME: ${TELEGRAM_BOT_USERNAME:-titan_core_bot}
      
      # ERP
      ERP_URL: ${ERP_URL:-http://erp.accord.uz}
      ERP_API_KEY: ${ERP_API_KEY}
      ERP_API_SECRET: ${ERP_API_SECRET}
      
      # Optional Webhook (for production)
      TELEGRAM_WEBHOOK_URL: ${TELEGRAM_WEBHOOK_URL}
      TELEGRAM_WEBHOOK_SECRET: ${TELEGRAM_WEBHOOK_SECRET}
    ports:
      - "4000:4000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - titan-network
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:

networks:
  titan-network:
    driver: bridge

# ============================================
# File: titan_bridge/docker-compose.dev.yml
# ============================================
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: titan-bridge-db-dev
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: titan_bridge_dev
    ports:
      - "5433:5432"
    volumes:
      - postgres_dev_data:/var/lib/postgresql/data
    networks:
      - titan-dev-network

  redis:
    image: redis:7-alpine
    container_name: titan-bridge-redis-dev
    ports:
      - "6380:6379"
    networks:
      - titan-dev-network

volumes:
  postgres_dev_data:

networks:
  titan-dev-network:
    driver: bridge

# ============================================
# File: titan_bridge/.env.example
# ============================================
# Copy this to .env and fill in your values

# Database
DATABASE_URL=ecto://postgres:postgres@localhost/titan_bridge_dev

# Phoenix
PORT=4000
PHX_HOST=localhost
SECRET_KEY_BASE=generate_with_mix_phx_gen_secret

# Security (generate strong keys)
SESSION_ENCRYPTION_KEY=32-byte-random-key-here-123456789012
TITAN_API_TOKEN=your-secure-api-token

# Telegram Bot (get from @BotFather)
TELEGRAM_BOT_TOKEN=1234567890:ABCdefGHIjklMNOpqrsTUVwxyz
TELEGRAM_BOT_USERNAME=your_bot_username

# Optional: Webhook for production
TELEGRAM_WEBHOOK_URL=https://your-domain.com/telegram/webhook
TELEGRAM_WEBHOOK_SECRET=random-secret-for-webhook

# ERPNext
ERP_URL=https://erp.accord.uz
ERP_API_KEY=your-api-key
ERP_API_SECRET=your-api-secret

# ============================================
# File: titan_bridge/rel/overlays/bin/server
# ============================================
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./titan_bridge start

# ============================================
# File: titan_bridge/rel/overlays/bin/server.bat
# ============================================
@echo off
setlocal enabledelayedexpansion

if not exist "%~dp0\titan_bridge.exe" (
    echo Error: titan_bridge.exe not found
    exit /b 1
)

"%~dp0\titan_bridge.exe" start

# ============================================
# File: titan_bridge/rel/overlays/bin/migrate
# ============================================
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./titan_bridge eval TitanBridge.Release.migrate

# ============================================
# File: titan_bridge/lib/titan_bridge/release.ex
# ============================================
defmodule TitanBridge.Release do
  @moduledoc """
  Release tasks for database migrations.
  """
  
  @app :titan_bridge

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end

# ============================================
# File: titan_bridge/run.sh
# ============================================
#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check dependencies
check_deps() {
    log_step "Checking dependencies..."
    
    if ! command -v elixir &> /dev/null; then
        log_error "Elixir is not installed"
        exit 1
    fi
    
    if ! command -v mix &> /dev/null; then
        log_error "Mix is not available"
        exit 1
    fi
    
    ELIXIR_VERSION=$(elixir --version | grep "Elixir" | awk '{print $2}')
    log_info "Elixir version: $ELIXIR_VERSION"
}

# Setup project
setup() {
    log_step "Setting up project..."
    cd "$SCRIPT_DIR"
    
    mix deps.get
    mix compile
    
    log_info "Setup completed"
}

# Create database and run migrations
migrate() {
    log_step "Running database migrations..."
    cd "$SCRIPT_DIR"
    
    mix ecto.setup
}

# Run in development mode
dev() {
    log_step "Starting development server..."
    cd "$SCRIPT_DIR"
    
    # Check if .env exists
    if [ ! -f .env ]; then
        log_warn ".env file not found. Creating from example..."
        cp .env.example .env
        log_warn "Please edit .env file with your configuration before continuing."
        exit 1
    fi
    
    # Load environment variables
    export $(cat .env | grep -v '^#' | xargs)
    
    mix phx.server
}

# Run tests
test() {
    log_step "Running tests..."
    cd "$SCRIPT_DIR"
    
    mix test
}

# Build production release
build() {
    log_step "Building production release..."
    cd "$SCRIPT_DIR"
    
    export MIX_ENV=prod
    mix deps.get --only prod
    mix compile
    mix assets.deploy
    mix release
    
    log_info "Build completed. Release is in _build/prod/rel/titan_bridge"
}

# Docker commands
docker_dev() {
    log_step "Starting development Docker environment..."
    cd "$SCRIPT_DIR"
    
    docker-compose -f docker-compose.dev.yml up -d
    
    log_info "Services started:"
    log_info "  PostgreSQL: localhost:5433"
    log_info "  Redis: localhost:6380"
}

docker_prod() {
    log_step "Starting production Docker environment..."
    cd "$SCRIPT_DIR"
    
    if [ ! -f .env ]; then
        log_error ".env file required for production"
        exit 1
    fi
    
    docker-compose up --build -d
}

docker_stop() {
    log_step "Stopping Docker containers..."
    cd "$SCRIPT_DIR"
    
    docker-compose -f docker-compose.dev.yml down
    docker-compose down
}

# Generate secrets
generate_secrets() {
    log_step "Generating secrets..."
    
    cd "$SCRIPT_DIR"
    
    echo "SECRET_KEY_BASE=$(mix phx.gen.secret)"
    echo "SESSION_ENCRYPTION_KEY=$(openssl rand -base64 32)"
}

# Show help
show_help() {
    echo "Titan Bridge - Elixir Phoenix Application"
    echo ""
    echo "Usage: ./run.sh [command]"
    echo ""
    echo "Commands:"
    echo "  setup              Setup the project (deps, compile)"
    echo "  migrate            Create database and run migrations"
    echo "  dev                Start development server"
    echo "  test               Run tests"
    echo "  build              Build production release"
    echo "  docker-dev         Start development Docker environment"
    echo "  docker-prod        Start production Docker environment"
    echo "  docker-stop        Stop all Docker containers"
    echo "  generate-secrets   Generate required secrets"
    echo "  help               Show this help"
    echo ""
    echo "Environment:"
    echo "  Create .env file from .env.example before running dev"
}

# Main
case "${1:-help}" in
    setup)
        check_deps
        setup
        ;;
    migrate)
        check_deps
        migrate
        ;;
    dev)
        check_deps
        dev
        ;;
    test)
        check_deps
        test
        ;;
    build)
        check_deps
        build
        ;;
    docker-dev)
        docker_dev
        ;;
    docker-prod)
        docker_prod
        ;;
    docker-stop)
        docker_stop
        ;;
    generate-secrets)
        generate_secrets
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
