# XLCU (Local Core Extensions)

[English](README.en.md)

XLCU ERPNext bilan zavod/ombordagi "temir"larni (printer, tarozi, UHF RFID) barqaror va past latency bilan bog'laydigan lokal stack.

Bu repo maqsadi:

- "1 buyruq = run": jamoada hamma bir xil yo'l bilan ishga tushiradi.
- "Menda ishladi" emas, "hammada ishlasin": Docker Compose, cache, doctor, support bundle.
- Low-spec kompyuterlar uchun: faqat kerakli child appni ko'tarish, publish/build cache, minimal qayta build.

## Ish Jarayoni (End-to-End Workflow)

Zebra (label/encode):

- Operator Zebra web/TUI orqali ishlaydi.
- Core-agent Zebra web API orqali tarozidan og'irlik o'qiydi va label bosadi.
- EPC (RFID kod) bridge orqali conflict tekshiruvdan o'tadi (lokal registry + ERPNext check).
- Print/encode bo'lgach EPC ERPNext'dagi draft'ga yoziladi (default: `Stock Entry Item.barcode`) va keyingi jarayon uchun tayyor bo'ladi.

RFID (submit):

- UHF reader EPC o'qiydi, RFID web UI esa inventory holatini ko'rsatadi.
- Bridge ichidagi Telegram bot EPC'larni tinglaydi, cache'dan mos draft'ni topadi va ERPNext'ga submit yuboradi.
- Cache davriy yangilanadi va webhook bo'lsa draft yaratilishi bilan darhol update bo'ladi.

## Komponentlar

Default `make run` stack (`docker-compose.run.yml`):

- `lce-bridge-dev` (Elixir) - API, Telegram bot, ERPNext integratsiya, child app launcher.
- `lce-postgres-dev` (PostgreSQL) - bridge sozlamalari va cache (dev rejimida `.cache/` ga persist).
- `lce-core-agent-dev` (.NET) - optional; `zebra/all` uchun default yoqiladi, `rfid` uchun `auto` rejimda o'chadi.

Child app'lar alohida repo sifatida keladi va XLCU git'iga kirmaydi (gitignore):

- Zebra child: `ERPNext_Zebra_stabil_enterprise_version/`
- RFID child: `ERPNext_UHFReader288_integration/`

XLCU birinchi ishga tushishda child repo'larni topa olmasa avtomatik `git clone` qiladi (`scripts/fetch_children.sh`).

## Talablar

Minimal (tavsiya etiladigan) talablar:

- Linux (USB/serial uchun eng to'g'ri).
- Docker va Docker Compose (`docker compose` yoki `docker-compose`).
- `git`, `curl`, `make`.

Hardware bilan ishlaganda:

- Rootless Docker tavsiya etilmaydi (USB/serial ko'rinmasligi mumkin).
- Linux'da user'ni `dialout` (serial) va kerak bo'lsa `lp` (printer) guruhiga qo'shish kerak bo'lishi mumkin.

## Xavfsizlik va Persistency (enterprise)

- Telegram token `.tg_token` ga saqlanadi (chmod 600) va gitignore.
- ERPNext API credential'lar Postgres'da shifrlangan holda saqlanadi (`CLOAK_KEY`, AES-256-GCM).
- Dev rejimda `make run` `CLOAK_KEY`ni avtomatik generatsiya qiladi va `.cache/lce-cloak.key` ga qo'yadi (key o'zgarmasa, tokenlar ham o'qiladi).
- Production'da `CLOAK_KEY`ni env orqali berish va Postgres volume'ni persist qilish tavsiya etiladi.
- Core-agent WS auth: production'da `LCE_CORE_TOKEN` qo'ying (bridge + core-agent bir xil token bilan).

## Tez Start (Docker-first, enterprise-friendly)

1. System prereq (Ubuntu/Debian yoki Arch):

```bash
make bootstrap
```

2. Telegram bot token:

- Interaktiv: `make run` token so'raydi va `.tg_token` ga saqlaydi (gitignore).
- Non-interaktiv/CI: `TG_TOKEN=... make run` yoki `.env.run` orqali.

3. Ishga tushirish:

```bash
make run
```

`make run` sizdan extension tanlashni so'raydi (Zebra yoki RFID) va tayyor bo'lganda URL beradi.

To'xtatish:

```bash
docker compose -f docker-compose.run.yml -p lce down
```

## Ishga Tushirish Rejimlari

- Default: `make run` (compose, cache, avtomatik child fetch, default restart).
- Faqat RFID: `LCE_CHILDREN_TARGET=rfid make run` yoki interaktiv tanlang.
- Faqat Zebra: `LCE_CHILDREN_TARGET=zebra make run` yoki interaktiv tanlang.
- Simulyatsiya (hardware yo'q bo'lsa):

```bash
make run-sim
make run-sim-rfid
```

- Hardware uchun (USB/serial access): `make run-hw` (privileged).
- Legacy run (eski docker-run flow): `make run-legacy`.

## Portlar

Default portlar:

- Bridge API: `http://127.0.0.1:4000/` (`/api/health`, `/api/status`, `/api/config`)
- Zebra web: `http://127.0.0.1:18000/` (health: `/api/v1/health`)
- RFID web: `http://127.0.0.1:8787/`
- Postgres: `127.0.0.1:5432`

O'zgartirish:

```bash
LCE_PORT=4001 ZEBRA_WEB_PORT=18001 RFID_WEB_PORT=8788 make run
```

## RFID Workflow (Operator)

1. `make run` -> RFID tanlang.
2. Web UI: `http://127.0.0.1:8787/`
3. Telegram bot:

- `/start` yoki `/reset` - setup wizard (ERP URL -> API KEY -> API SECRET).
- `/scan` - draft cache tekshiradi, RFID inventory'ni yoqadi va EPC'larni tinglaydi.
- `/stop` - inventory/scan to'xtaydi.
- `/status` - holat va reader status.
- `/list` - pending draft ro'yxati.
- `/turbo` - ERPNext'dan draft/EPC cache'ni majburan yangilash.
- `/submit` - UHF bo'lmasa ham manual submit (inline menu orqali).

Eslatma: XLCU RFID child app ichidagi "ERP heartbeat/push" oqimini default o'chiradi (`LCE_RFID_FORCE_LOCAL_PROFILE=1`), chunki ERPNext bilan sinxronni bridge boshqaradi. Bu turli "fetch failed" warning va pause holatlarni kamaytiradi.

## ERPNext Integratsiya (RFID, enterprise tavsiya)

XLCU RFID tez ishlashi uchun draft cache kerak. Ikki yo'l:

1. Polling: bot ERPNext'dan davriy cache yangilaydi (default 3 daqiqada 1 marta).
2. Webhook (tavsiya): ERPNext draft yaratilganda darhol XLCU'ga event yuboradi, cache tez yangilanadi va oldin o'qilgan EPC ham darhol submitga ketishi mumkin.

XLCU webhook receiver:

- `POST http://<xlcu-host>:4000/api/webhook/erp`

Muhim xavfsizlik eslatmasi:

- `POST /api/webhook/erp` default holatda auth talab qilmaydi.
- Enterprise deploy'da bu endpoint'ni faqat ERPNext serverdan keladigan tarmoq orqali cheklash tavsiya etiladi (VPN, firewall ACL, reverse proxy allowlist).

## Zebra Workflow (Operator)

1. `make run` -> Zebra tanlang.
2. Web UI: `http://127.0.0.1:18000/`
3. TUI: Zebra tanlanganda default auto ochiladi. Terminal render muammo bersa:

```bash
LCE_SHOW_ZEBRA_TUI=0 make run
```

Device troubleshooting (container ichida):

```bash
docker exec lce-bridge-dev ls -la /dev/ttyUSB* /dev/ttyACM* /dev/usb/lp* 2>/dev/null || true
```

Scale portni qo'lda berish:

```bash
ZEBRA_SCALE_PORT=/dev/ttyUSB0 make run
```

## Konfiguratsiya (asosiy env)

Jamoa uchun bir xil profil:

```bash
cp .env.run.example .env.run
export $(grep -v '^#' .env.run | xargs)
make run
```

Eng ko'p ishlatiladigan env'lar:

- `TG_TOKEN` - Telegram bot token.
- `LCE_CHILDREN_TARGET` - `zebra` | `rfid` | `all`.
- `LCE_FORCE_RESTART` - default `1` (stale polling conflict bo'lmasligi uchun har run restart).
- `LCE_DOCKER_PRIVILEGED` - default `1` (USB/serial uchun).
- `LCE_USE_PREBUILT_DEV_IMAGE` - `1` bo'lsa local build skip, image pull.
- `LCE_REBUILD_IMAGE` - `1` bo'lsa bridge image majburan rebuild.
- `LCE_ENABLE_CORE_AGENT` - `auto` | `0` | `1`.
- `RFID_SCAN_SUBNETS` - LAN scan CIDR ro'yxati (vergul bilan). Default avtomatik aniqlanadi.

## Performance va Low-Spec Tavsiyalar

- Faqat kerakli target: `LCE_CHILDREN_TARGET=rfid` yoki `zebra`.
- 1-marta ishga tushishda image pull/build og'ir bo'lishi normal (Dotnet SDK, deps). Keyingi run'lar cache hisobiga tezlashadi.
- Kuchsiz PC (mini-PC/Raspberry) uchun tavsiya: **local build qilmasdan**, prebuilt dev image'ni pull qiling:

```bash
LCE_USE_PREBUILT_DEV_IMAGE=1 make run
```

Izoh: bu rejimda image avtomatik `ghcr.io/<owner>/xlcu-bridge-dev:<target>` dan olinadi (git `origin` GitHub bo'lsa). Agar kerak bo'lsa qo'lda berishingiz mumkin:

```bash
LCE_USE_PREBUILT_DEV_IMAGE=1 \
LCE_DEV_IMAGE=ghcr.io/<owner>/xlcu-bridge-dev:bridge-rfid \
make run
```

Qo'shimcha: `make run` default holatda ham prebuilt image'ni **avtomatik sinab ko'radi** (birinchi ishga tushishda), agar topilmasa local build'ga fallback qiladi. Avtomatik prebuilt'ni o'chirish:

```bash
LCE_PREBUILT_AUTO=0 make run
```

- `RFID_SCAN_SUBNETS` ni real tarmoqqa toraytiring (scan tez bo'ladi).
- Offline/sekin internet bo'lsa child repo'larni oldindan olib qo'ying:

```bash
bash scripts/fetch_children.sh
```

- Diagnostika uchun:

```bash
make doctor
make support-bundle
```

## Troubleshooting (eng ko'p uchraydiganlar)

1. Port band:

- `make doctor` port conflict'ni ko'rsatadi.
- Portni o'zgartiring: `ZEBRA_WEB_PORT=18001 make run`

2. Docker yo'q yoki daemon ishlamayapti:

- `make bootstrap`
- `sudo systemctl start docker`

3. `Docker Compose requires buildx plugin` warning:

- Docker buildx/plugin'ni o'rnating (Ubuntu/Debian: `docker-compose-plugin`).

4. RFID web ochilmayapti (`127.0.0.1:8787`):

- `docker compose -f docker-compose.run.yml -p lce ps`
- `docker compose -f docker-compose.run.yml -p lce logs --tail=200 bridge`

## Versionlarni Barqaror Qilish (enterprise)

Child repo'larni branch/tag bo'yicha pin qilish mumkin:

```bash
ZEBRA_REF=v1.2.3 RFID_REF=v1.2.3 bash scripts/fetch_children.sh
```

Yoki production'da `LCE_ZEBRA_HOST_DIR` / `LCE_RFID_HOST_DIR` bilan o'zingiz pinned clone ishlating.
