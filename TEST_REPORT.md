# LCE Smoke Test Report

Date: 2026-02-09

This document records a quick smoke test to confirm the LCE runtime can build and the bridge can start.

## Environment

- OS: Linux (Arch)
- Docker Engine (server): `29.1.3`
- `docker buildx`: not installed on this host (`docker: unknown command: docker buildx`)

## Smoke Test Steps (Repeatable)

```bash
cd LCE

# 1) Sanity checks (paths + Docker daemon + runner script syntax)
make doctor

# 1.1) Auto-fetch child repos when missing (safe dry-run)
# This verifies fresh installs don't need manual clones.
tmp="$(mktemp -d)"
LCE_WORK_DIR="$tmp" LCE_CHILDREN_TARGET=zebra LCE_DRY_RUN=1 LCE_QUIET=1 bash scripts/run_extensions.sh
LCE_WORK_DIR="$tmp" LCE_CHILDREN_TARGET=rfid  LCE_DRY_RUN=1 LCE_QUIET=1 bash scripts/run_extensions.sh

# 2) Ensure the dev runtime image builds on hosts without buildx/BuildKit
DOCKER_BUILDKIT=0 docker build \
  -t lce-bridge-dev:elixir-1.16.2-dotnet-10.0 \
  -f src/bridge/Dockerfile.dev \
  src/bridge

# 3) Compile check (bridge)
# If you already have a running container:
docker exec lce-bridge-dev bash -lc 'cd /app && mix compile'

# 4) Endpoint checks (bridge + selected extension)
curl -fsS http://127.0.0.1:4000/api/health
curl -fsS http://127.0.0.1:4000/api/status
curl -fsS http://127.0.0.1:8787/api/status   # when RFID is running
curl -fsS http://127.0.0.1:18000/api/status  # when Zebra is running
```

## Results (This Run)

1. `make doctor`: OK
2. Auto-fetch (dry-run):
   - Zebra repo cloned (only when requested) and path resolved: OK
   - RFID repo cloned (only when requested) and path resolved: OK
2. `DOCKER_BUILDKIT=0 docker build ...Dockerfile.dev`: OK (build completed successfully)
3. `mix compile`: OK (warnings only)
4. `GET /api/health`: OK (`{"ok":true,...}`)
5. `GET /api/status`: OK (service up; config values are masked by the API)
6. RFID `GET /api/status`: OK (RFID service responded; `connected` may be `false` if no reader is attached)
