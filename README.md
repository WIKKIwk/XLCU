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
│   ├── ARCHITECTURE.md          # Arxitektura tavsifi
│   ├── DEPLOYMENT.md            # Deploy qilish
│   ├── DEVELOPMENT.md           # Development
│   ├── TELEGRAM.md              # Telegram workflow
│   └── SECURITY.md              # Xavfsizlik
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
│   ├── setup.sh
│   ├── deploy.sh
│   └── backup.sh
│
└── .github/                     # CI/CD
    └── workflows/
        ├── ci.yml
        ├── cd-staging.yml
        └── cd-production.yml
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

### Eng oson (kafolatli) usul: Docker bilan `make run`

Bu rejimda host kompyuterda Elixir/.NET/Java/Node o'rnatish shart emas (faqat Docker kerak).

```bash
cd LCE
make doctor
make run
# yoki majburan docker:
# make run-docker
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

Kerak bo'lsa lokal rejimga majburlash:

```bash
LCE_FORCE_LOCAL=1 make run
```

### Development rejimida ishga tushirish:

```bash
# 1. C# Core
cd LCE/src/core
dotnet build
dotnet run --project src/Titan.Host

# 2. Elixir Bridge
cd LCE/src/bridge
mix deps.get
mix ecto.setup
mix run --no-halt

# 3. Docker Compose bilan
cd LCE
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
cd LCE
docker-compose up -d
git init
git add .
git commit -m "Initial LCE commit"
git remote add origin https://github.com/accord/lce.git
git push -u origin main
```

---

**LCE tayyor!** 🚀
