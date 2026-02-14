# XLCU (Local Core Extensions)

[Uzbek](README.md)

XLCU is a local stack that connects ERPNext with on-prem / warehouse "hardware" (printer, scale, UHF RFID) in a stable, low-latency way.

Repo goals:

- "1 command = run": everyone on the team starts it the same way.
- Not "works on my machine" but "works everywhere": Docker Compose, caches, doctor, support bundle.
- Low-spec friendly: bring up only the needed child app, publish/build caches, minimal rebuilds.

## End-to-End Workflow

Zebra (label/encode):

- Operator works via the Zebra web/TUI.
- Core-agent reads weight from the scale and prints labels via the Zebra web API.
- EPC (RFID code) is checked for conflicts via the bridge (local registry + ERPNext check).
- After print/encode, the EPC is written into the ERPNext draft (default: `Stock Entry Item.barcode`) and becomes ready for the next steps.

RFID (submit):

- The UHF reader reads EPCs; the RFID web UI shows inventory status.
- The Telegram bot inside the bridge listens for EPCs, matches them from cache, and submits the corresponding draft to ERPNext.
- Cache is refreshed periodically; with webhooks it updates immediately on draft creation.

## Components

Default `make run` stack (`docker-compose.run.yml`):

- `lce-bridge-dev` (Elixir) - API, Telegram bot, ERPNext integration, child app launcher.
- `lce-postgres-dev` (PostgreSQL) - bridge settings and cache (persisted under `.cache/` in dev).
- `lce-core-agent-dev` (.NET) - optional; enabled by default for `zebra/all`, disabled for `rfid` in `auto` mode.

Child apps are separate repos and are not committed into XLCU (gitignored):

- Zebra child: `ERPNext_Zebra_stabil_enterprise_version/`
- RFID child: `ERPNext_UHFReader288_integration/`

On first run, if child repos are missing, XLCU auto-clones them (`scripts/fetch_children.sh`).

## Requirements

Minimum (recommended):

- Linux (best for USB/serial).
- Docker and Docker Compose (`docker compose` or `docker-compose`).
- `git`, `curl`, `make`.

With hardware:

- Rootless Docker is not recommended (USB/serial may not be accessible).
- On Linux you may need to add your user to the `dialout` (serial) and possibly `lp` (printer) groups.

## Security and Persistence (enterprise)

- Telegram token is stored in `.tg_token` (chmod 600) and is gitignored.
- ERPNext API credentials are stored encrypted in Postgres (`CLOAK_KEY`, AES-256-GCM).
- In dev, `make run` auto-generates `CLOAK_KEY` and persists it into `.cache/lce-cloak.key` (as long as the key stays the same, stored tokens remain readable).
- In production, provide `CLOAK_KEY` via env and persist the Postgres volume.
- Core-agent WS auth: in production set `LCE_CORE_TOKEN` (same value on bridge and core-agent).

## Quickstart (Docker-first, enterprise-friendly)

1. Install system prerequisites (Ubuntu/Debian or Arch):

```bash
make bootstrap
```

2. Telegram bot token:

- Interactive: `make run` will prompt and store into `.tg_token` (gitignored).
- Non-interactive/CI: `TG_TOKEN=... make run` or via `.env.run`.

3. Start:

```bash
make run
```

`make run` asks which extension to start (Zebra or RFID) and prints a URL once ready.

Stop:

```bash
docker compose -f docker-compose.run.yml -p lce down
```

## Run Modes

- Default: `make run` (compose, caches, auto child fetch, restart by default).
- RFID only: `LCE_CHILDREN_TARGET=rfid make run` or choose interactively.
- Zebra only: `LCE_CHILDREN_TARGET=zebra make run` or choose interactively.
- Simulation (no hardware):

```bash
make run-sim
make run-sim-rfid
```

- Hardware mode (USB/serial access): `make run-hw` (privileged).
- Legacy run (old docker-run flow): `make run-legacy`.

## Ports

Default ports:

- Bridge API: `http://127.0.0.1:4000/` (`/api/health`, `/api/status`, `/api/config`)
- Zebra web: `http://127.0.0.1:18000/` (health: `/api/v1/health`)
- RFID web: `http://127.0.0.1:8787/`
- Postgres: `127.0.0.1:5432`

Override:

```bash
LCE_PORT=4001 ZEBRA_WEB_PORT=18001 RFID_WEB_PORT=8788 make run
```

## RFID Workflow (Operator)

1. `make run` -> choose RFID.
2. Web UI: `http://127.0.0.1:8787/`
3. Telegram bot:

- `/start` or `/reset` - setup wizard (ERP URL -> API KEY -> API SECRET).
- `/scan` - checks/refreshes draft cache, starts RFID inventory and listens for EPCs.
- `/stop` - stops inventory/scan.
- `/status` - current state + reader status.
- `/list` - pending draft list.
- `/turbo` - force refresh draft/EPC cache from ERPNext.
- `/submit` - manual submit even without UHF (via inline menu).

Note: XLCU disables the RFID child app internal "ERP heartbeat/push" flow by default (`LCE_RFID_FORCE_LOCAL_PROFILE=1`) because ERPNext sync is managed by the bridge. This reduces "fetch failed" warnings and inventory pauses.

## ERPNext Integration (RFID, enterprise recommendation)

To keep RFID latency low, XLCU maintains a draft/EPC cache. Two options:

1. Polling: periodic refresh (default every 3 minutes).
2. Webhook (recommended): ERPNext sends an event to XLCU on draft creation, cache updates immediately and a previously read EPC can be submitted right away.

XLCU webhook receiver:

- `POST http://<xlcu-host>:4000/api/webhook/erp`

Security note:

- `POST /api/webhook/erp` does not require auth by default.
- In enterprise deployments, restrict this endpoint to the ERPNext server network (VPN, firewall ACL, reverse proxy allowlist).

## Zebra Workflow (Operator)

1. `make run` -> choose Zebra.
2. Web UI: `http://127.0.0.1:18000/`
3. TUI: auto-opens by default when Zebra is selected. If your terminal renders badly:

```bash
LCE_SHOW_ZEBRA_TUI=0 make run
```

Device troubleshooting (inside container):

```bash
docker exec lce-bridge-dev ls -la /dev/ttyUSB* /dev/ttyACM* /dev/usb/lp* 2>/dev/null || true
```

Specify scale port manually:

```bash
ZEBRA_SCALE_PORT=/dev/ttyUSB0 make run
```

## Configuration (main env)

Team-wide profile:

```bash
cp .env.run.example .env.run
export $(grep -v '^#' .env.run | xargs)
make run
```

Common env vars:

- `TG_TOKEN` - Telegram bot token.
- `LCE_CHILDREN_TARGET` - `zebra` | `rfid` | `all`.
- `LCE_FORCE_RESTART` - default `1` (avoids stale polling conflicts by restarting each run).
- `LCE_DOCKER_PRIVILEGED` - default `1` (USB/serial).
- `LCE_USE_PREBUILT_DEV_IMAGE` - default `1` (no local builds, pull image).
- `LCE_PREBUILT_ONLY` - default `1` (fail-fast on pull errors; no local build fallback).
- `LCE_REBUILD_IMAGE` - if `1`, force rebuild bridge image.
- `LCE_ENABLE_CORE_AGENT` - `auto` | `0` | `1`.
- `RFID_SCAN_SUBNETS` - LAN scan CIDRs (comma-separated). Default auto-detected.

## Performance and Low-Spec Tips

- Start only what you need: `LCE_CHILDREN_TARGET=rfid` or `zebra`.
- First run can be heavy due to image pull/build (Dotnet SDK, deps). Next runs are faster thanks to caches.
- Default: local builds are disabled. `make run` uses prebuilt images and will stop with an error if it cannot pull them (no hour-long builds).

```bash
make run
```

Note: in this mode, the script auto-derives `ghcr.io/<owner>/xlcu-bridge-dev:<target>` from the git `origin` (when it is a GitHub remote). You can also set it explicitly:

```bash
LCE_USE_PREBUILT_DEV_IMAGE=1 \
LCE_DEV_IMAGE=ghcr.io/<owner>/xlcu-bridge-dev:bridge-rfid \
make run
```

Additionally: by default `make run` will **auto-try prebuilt images on first run** and fall back to a local build if it cannot pull. Disable auto-prebuilt:

```bash
LCE_PREBUILT_AUTO=0 make run
```

- Narrow `RFID_SCAN_SUBNETS` to the actual network to speed up discovery.
- Pre-fetch child repos if internet is slow/offline:

```bash
bash scripts/fetch_children.sh
```

- For diagnostics:

```bash
make doctor
make support-bundle
```

## Troubleshooting (common)

1. Port already in use:

- `make doctor` shows port conflicts.
- Change ports: `ZEBRA_WEB_PORT=18001 make run`

2. Docker missing or daemon not running:

- `make bootstrap`
- `sudo systemctl start docker`

3. `Docker Compose requires buildx plugin` warning:

- Install docker buildx/plugin (Ubuntu/Debian: `docker-compose-plugin`).

4. RFID web not reachable (`127.0.0.1:8787`):

- `docker compose -f docker-compose.run.yml -p lce ps`
- `docker compose -f docker-compose.run.yml -p lce logs --tail=200 bridge`

## Pinning Versions (enterprise)

You can pin child repos to a branch/tag:

```bash
ZEBRA_REF=v1.2.3 RFID_REF=v1.2.3 bash scripts/fetch_children.sh
```

Or in production use pinned clones via `LCE_ZEBRA_HOST_DIR` / `LCE_RFID_HOST_DIR`.
