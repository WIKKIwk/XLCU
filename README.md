# LCE - Local Core Extensions (Complete Project Guide)

## 📁 Loyiha Tuzilishi

Barcha kodlarni quyidagi strukturada joylashtiring:

```
LCE/
├── README.md                    # Ushbu fayl
├── docker-compose.yml           # Asosiy docker-compose
├── Makefile                     # Yordamchi komandalar
│
├── docs/                        # Hujjatlar
│   ├── COMPLETE.md              # To'liq qo'llanma
│   ├── CORE_README.md           # Core haqida
│   ├── BRIDGE_README.md         # Bridge haqida
│   ├── INTEGRATION.md           # Integratsiya
│   ├── TESTING_README.md        # Testlar
│   ├── MONITORING_README.md     # Monitoring
│   └── ARCHIVE.md               # Arxiv/eslatmalar
│
├── src/                         # Asosiy kodlar
│   ├── core/                    # C# .NET 10 Core
│   │   ├── src/
│   │   │   ├── Titan.Domain/
│   │   │   ├── Titan.Core/
│   │   │   ├── Titan.Infrastructure/
│   │   │   ├── Titan.TUI/
│   │   │   └── Titan.Host/
│   │   ├── tests/
│   │   └── Dockerfile
│   │
│   ├── bridge/                  # Elixir Phoenix
│   │   ├── lib/
│   │   │   ├── titan_bridge/
│   │   │   └── titan_bridge_web/
│   │   ├── test/
│   │   ├── config/
│   │   └── Dockerfile
│   │
│   └── shared/                  # Umumiy protokollar
│       └── protocol.md
│
├── k8s/                         # Kubernetes
│   ├── base/
│   │   ├── namespace.yml
│   │   ├── deployment-core.yml
│   │   ├── deployment-bridge.yml
│   │   ├── service-core.yml
│   │   ├── service-bridge.yml
│   │   ├── ingress.yml
│   │   ├── hpa-bridge.yml
│   │   ├── configmap-core.yml
│   │   ├── configmap-bridge.yml
│   │   ├── secret.yml
│   │   ├── network-policy.yml
│   │   └── kustomization.yml
│   │
│   └── overlays/
│       ├── production/
│       └── staging/
│
├── helm/                        # Helm Charts
│   └── titan/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-production.yaml
│       ├── values-staging.yaml
│       ├── templates/
│       └── README.md
│
├── terraform/                   # Infrastructure as Code
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│
├── monitoring/                  # Monitoring stack
│   ├── docker-compose.monitoring.yml
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   └── alertmanager/
│
├── scripts/                     # Yordamchi skriptlar
│   ├── bootstrap.sh
│   ├── doctor.sh
│   ├── fetch_children.sh
│   └── run_extensions.sh
│
└── .github/                     # CI
    └── workflows/
        └── PROJECT_TITAN_CICD.yml
```

## 📦 Loyiha Strukturasi

### 1. C# Core (src/core/) — TAYYOR
Barcha fayllar `PROJECT_TITAN_*.cs` dan ajratilgan:
- `Titan.Domain/` — Entity, ValueObject, Event, Interface
- `Titan.Core/` — FSM, StabilityDetector, BatchProcessingService
- `Titan.Infrastructure/` — EF Core, Hardware drivers, EPC Generator
- `Titan.Host/` — Health checks, Structured logging, Graceful shutdown
- `Titan.TUI/` — Terminal.Gui interfeysi

### 2. Elixir Bridge (src/bridge/) — TAYYOR + XAVFSIZ
- Cloak bilan token shifrlash (AES-GCM)
- Production'da auth majburiy (EnvValidator)
- API auth (Bearer token), Rate limiting (Hammer), Security headers
- Telegram xabar o'chirish (credential xabarlar)

### 3. Deploy — TAYYOR
- `docker-compose.yml` — PostgreSQL + Bridge + Core
- `k8s/base/manifests.yml` — Kubernetes manifestlar
- `helm/titan/` — Helm Charts
- `.env.example` — barcha kerakli env var'lar

## 🚀 Tez Boshlash

### Eng oson (kafolatli) usul: Docker Compose bilan `make run`

Bu rejimda host kompyuterda Elixir/.NET/Java/Node o'rnatish shart emas (faqat Docker + Docker Compose kerak).

```bash
cd XLCU
make bootstrap   # Ubuntu/Arch: git + docker va kerakli utilitalar
cp .env.run.example .env.run   # ixtiyoriy, jamoa uchun bir xil profil
make run
# ixtiyoriy: tekshiruv
make doctor
# yoki majburan docker:
# make run-docker
```

Eslatma: `make bootstrap` sizni `docker` group'ga qo'shishi mumkin. Shundan keyin `logout/login` qiling yoki `newgrp docker`.

`make run` stack'i compose orqali quyidagilarni ko'taradi:

- `postgres` (`lce-postgres-dev`)
- `bridge` (`lce-bridge-dev`)
- `core-agent` (`lce-core-agent-dev`, default: `zebra/all` uchun yoqiladi, `rfid` uchun `auto` rejimda o'chadi)

`make run` endi targetga qarab faqat kerakli bridge texnologiyalarini build qiladi:

- `zebra` -> `bridge-zebra` (.NET + USB helperlar)
- `rfid` -> `bridge-rfid` (Node.js + Java)
- `all` -> `bridge-all` (.NET + Node.js + Java)

USB/Serial (printer/RFID/scale) bilan ishlash kerak bo'lsa `--privileged` rejimni yoqib ishlating:

```bash
make run-hw
# yoki:
make run LCE_DOCKER_PRIVILEGED=1
```

Eslatma: agar Docker **rootless** rejimda bo'lsa, USB/serial qurilmalar container ichida ishlamasligi mumkin (hatto `--privileged` bilan ham).

Eski (`docker run`-based) yo'lga qaytish kerak bo'lsa:

```bash
make run-legacy
```

Hardware-siz (CI/laptop) rasmiy simulyatsiya rejimi:

```bash
make run-sim
# RFID target bilan:
make run-sim-rfid
```

Prebuilt dev image ishlatish (mahalliy build farqlarini kamaytirish):

```bash
LCE_USE_PREBUILT_DEV_IMAGE=1 \
LCE_DEV_IMAGE=ghcr.io/<org>/xlcu-bridge-dev:bridge-zebra \
make run
```

Core-agent'ni majburan yoqish/o'chirish:

```bash
# rfid uchun ham core-agent ko'tarish
LCE_CHILDREN_TARGET=rfid LCE_ENABLE_CORE_AGENT=1 make run

# zebra uchun core-agent'siz tezroq startup
LCE_CHILDREN_TARGET=zebra LCE_ENABLE_CORE_AGENT=0 make run
```

Core-agent kutish rejimi (startup tezligi uchun):

```bash
# default: kutmaydi (tezroq "tayyor!" chiqadi)
LCE_WAIT_CORE_READY=0 make run

# to'liq tayyorlikni kutish kerak bo'lsa
LCE_WAIT_CORE_READY=1 make run
```

Zebra TUI terminalda buzilib ko'rinsa:

```bash
# auto TUI o'chirish (stable)
LCE_SHOW_ZEBRA_TUI=0 make run
```

Izoh: `make run` endi TUI ishga tushirganda `TERM/COLUMNS/LINES` ni container ichiga uzatadi; ko'p terminal muhitlarda shu bilan render barqarorlashadi.

Low-spec qurilmalar uchun (mini-PC/Raspberry) qo'shimcha optimizatsiya:

- `core-agent` endi `dotnet run` o'rniga publish-cache bilan ishlaydi (source o'zgarmasa qayta compile qilinmaydi).
- cache papka: `.cache/lce-core-publish` (`LCE_CORE_PUBLISH_CACHE_DIR` bilan override qilish mumkin).
- Zebra uchun NuGet cache ham persist qilinadi (`.cache/lce-bridge-nuget`), va `run.sh` fast-path `--no-restore` bilan ishga tushadi (fallback build saqlangan).
- Bridge image build ham fingerprint bo'yicha cache qilinadi: source va `Dockerfile.dev` o'zgarmasa `docker build` skip qilinadi (`LCE_REBUILD_IMAGE=1` bilan majburan rebuild).

USB ko'rinyaptimi tekshirish (container ichida):

```bash
docker exec lce-bridge-dev lsusb
docker exec lce-bridge-dev ls -la /dev/ttyUSB* /dev/ttyACM* /dev/usb/lp* 2>/dev/null || true
```

Tarozi (scale) tekshiruvi:

```bash
curl -fsS http://127.0.0.1:18000/api/v1/scale/ports
curl -fsS http://127.0.0.1:18000/api/v1/scale
```

Eslatma: hozircha ZebraBridge tarozi o'qish uchun **serial port** (`/dev/ttyUSB*`, `/dev/ttyACM*`) dan foydalanadi. Agar portlar bo'sh chiqsa, tarozi HID bo'lishi yoki Docker ichida device ko'rinmayotgan bo'lishi mumkin.

`make run` (va ZebraBridge) scale portni imkon qadar **avtomatik** topadi:

- agar faqat bitta USB-serial port bo'lsa: avtomatik tanlaydi
- agar bir nechta port bo'lsa: ZebraBridge portlarni tezkor probe qilib scale'ni o'zi topishga harakat qiladi (user'dan port so'ramaydi)

Qo'lda ko'rsatish:

```bash
ZEBRA_SCALE_PORT=/dev/ttyUSB0 make run
```

Ko'p device bo'lganda (10+), by-id nomi bo'yicha hint berish (tavsiya):

```bash
# /dev/serial/by-id/* ichidagi substring (masalan FTDI, 1a86, CH340, va hokazo)
ZEBRA_SCALE_PORT_HINT=FTDI make run
```

Cache'ni tozalash (port o'zgargan bo'lsa):

```bash
rm -f .cache/zebra-scale.by-id
```

`make run` birinchi marta ishga tushganda, kerakli child repo'lar (Zebra/RFID) topilmasa ularni avtomatik yuklab oladi:

- Zebra: `https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git`
- RFID: `https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git`

Qo'llab-quvvatlanadigan papka nomlari:

- Zebra: `zebra_v1/` yoki `ERPNext_Zebra_stabil_enterprise_version/`
- RFID: `rfid/` yoki `ERPNext_UHFReader288_integration/`

Ixtiyoriy: oldindan yuklab olish (internet sekin/offline bo'lsa):

```bash
bash scripts/fetch_children.sh
```

Diagnostika arxivi (support bundle) olish:

```bash
make support-bundle
```

### RFID Telegram bot: draft submit (/submit)

- `/reset` (yoki `/start`) — bot holatini tozalaydi va sozlashni qaytadan boshlaydi.
- `/submit` — draft'ni inline qidirish orqali tanlab submit qiladi.
  - BotFather'da **Inline Mode** yoqilgan bo'lishi kerak.
  - inline natija tanlanganda chatga `submit_draft:<draft_name>` yuboriladi, bot uni avtomatik o'chirib, draft'ni submit qiladi.

Kerak bo'lsa lokal rejimga majburlash:

```bash
LCE_FORCE_LOCAL=1 make run
```

### Development rejimida ishga tushirish:

```bash
# 1. C# Core
cd src/core
dotnet build
dotnet run --project src/Titan.Host

# 2. Elixir Bridge
cd ../bridge
mix deps.get
mix ecto.setup
mix run --no-halt

# 3. Docker Compose bilan (repo root)
cd ../..
cp .env.example .env  # .env ni to'ldiring
docker compose up --build
```

### Production uchun kerakli env var'lar:
```bash
POSTGRES_PASSWORD=...
SECRET_KEY_BASE=...      # mix phx.gen.secret
CLOAK_KEY=...            # 32 byte random, base64
LCE_CORE_TOKEN=...       # Core <-> Bridge auth
LCE_WEBHOOK_SECRET=...   # ERP webhook HMAC
LCE_API_TOKEN=...        # API Bearer token
```

## 📊 Barcha Fayllar Ro'yxati

| Asl Fayl | Yangi Joy |
|----------|-----------|
| PROJECT_TITAN_DOMAIN.cs | LCE/src/core/src/Titan.Domain/ |
| PROJECT_TITAN_CORE.cs | LCE/src/core/src/Titan.Core/ |
| PROJECT_TITAN_INFRASTRUCTURE.cs | LCE/src/core/src/Titan.Infrastructure/ |
| PROJECT_TITAN_TUI.cs | LCE/src/core/src/Titan.TUI/ |
| PROJECT_TITAN_HOST.cs | LCE/src/core/src/Titan.Host/ |
| PROJECT_TITAN_DOCKER.cs | LCE/src/core/Dockerfile |
| PROJECT_TITAN_ELIXIR.exs | LCE/src/bridge/ |
| PROJECT_TITAN_ELIXIR2.exs | LCE/src/bridge/ |
| PROJECT_TITAN_ELIXIR3.exs | LCE/src/bridge/ |
| PROJECT_TITAN_TELEGRAM.exs | LCE/src/bridge/lib/titan_bridge/telegram/ |
| PROJECT_TITAN_ELIXIR_CONFIG.exs | LCE/src/bridge/config/ |
| PROJECT_TITAN_ELIXIR_DOCKER.exs | LCE/src/bridge/Dockerfile |
| PROJECT_TITAN_K8S_MANIFESTS.yml | LCE/k8s/base/ |
| PROJECT_TITAN_HELM_CHARTS.yml | LCE/helm/titan/ |
| PROJECT_TITAN_TERRAFORM.tf | LCE/terraform/ |
| PROJECT_TITAN_CICD.yml | LCE/.github/workflows/ |
| PROJECT_TITAN_MONITORING_*.yml | LCE/monitoring/ |
| PROJECT_TITAN_SECURITY.yml | LCE/k8s/security/ |
| PROJECT_TITAN_GITOPS_ARGOCD.yml | LCE/argocd/ |

## 📝 Eslatmalar

1. **Har bir PROJECT_TITAN_*.cs/exs fayldan** tegishli class/moduleni ajratib oling
2. **Namespace/Module nomlarini** saqlab qoling
3. **Using/Import larni** to'g'ri sozlang
4. **Dockerfile larni** tegishli joyga qo'ying
5. **Testlarni** alohida papkaga ajrating

## ✅ Tekshirish Ro'yxati

- [ ] C# Core kodlari `src/core/` da
- [ ] Elixir Bridge kodlari `src/bridge/` da
- [ ] K8s manifestlari `k8s/` da
- [ ] Helm chart `helm/titan/` da
- [ ] Terraform `terraform/` da
- [ ] Monitoring `monitoring/` da
- [ ] CI/CD `.github/workflows/` da
- [ ] README.md yaratilgan
- [ ] docker-compose.yml yaratilgan
- [ ] Makefile yaratilgan

## 🎯 Keyingi Qadam

Barcha fayllarni yuqoridagi strukturaga joylashtirgandan so'ng:

```bash
cd XLCU
docker compose up -d
```

---

**LCE tayyor!** 🚀
