# TITAN Bridge

TITAN Bridge — zavod ombor operatsiyalarini boshqaruvchi Elixir dastur.
Telegram bot orqali operator mahsulotni tortadi, etiket bosadi, ERPNext'da Stock Entry draft yaratadi.
RFID bot esa UHF reader bilan ishlaydi — tag o'qilganda mos draft avtomatik submit bo'ladi.

## Arxitektura

```
┌────────────────────────────────────────────────────────────────┐
│                        TITAN Bridge                            │
│                     (Elixir / OTP)                             │
│                                                                │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │ Telegram  │  │  RFID    │  │   ERP     │  │    Cache     │  │
│  │   Bot     │  │  Bot     │  │  Sync     │  │   (ETS)      │  │
│  │ (Zebra)   │  │ (RFID)   │  │  Worker   │  │              │  │
│  └─────┬─────┘  └────┬─────┘  └─────┬─────┘  └──────┬───────┘  │
│        │             │              │               │          │
│  ┌─────┴─────┐  ┌────┴─────┐  ┌────┴────┐   ┌─────┴───────┐  │
│  │  Children  │  │  RFID    │  │   ERP   │   │  PostgreSQL  │  │
│  │  Manager   │  │ Listener │  │  Client │   │    (Repo)    │  │
│  └─────┬─────┘  └────┬─────┘  └────┬────┘   └──────────────┘  │
│        │             │              │                          │
└────────┼─────────────┼──────────────┼──────────────────────────┘
         │             │              │
    ┌────┴────┐   ┌────┴────┐   ┌────┴─────┐
    │ zebra_v1│   │  rfid   │   │ ERPNext  │
    │ (C#)    │   │ (Java)  │   │ (Frappe) │
    │ :18000  │   │ :8787   │   │          │
    └─────────┘   └─────────┘   └──────────┘
```

### Komponentlar

| Komponent | Vazifasi |
|-----------|----------|
| **Telegram.Bot** | Asosiy operator interfeysi. Mahsulot tanlash, tortish, etiket bosish, draft yaratish |
| **Telegram.RfidBot** | RFID operator interfeysi. UHF reader boshqarish, EPC bo'yicha draft auto-submit |
| **Children** | OS jarayon menejeri. `zebra_v1` va `rfid` dasturlarini Port orqali ishga tushiradi |
| **RfidListener** | RFID server'dan tag polling (har 1 soniya). Yangi EPC bo'lsa subscriber'larga xabar |
| **ErpSyncWorker** | ERPNext'dan har 10 soniyada ma'lumot sync (items, warehouses, bins, drafts) |
| **Cache** | ETS in-memory cache. ERPNext ma'lumotlari tarmoqsiz o'qiladi |
| **ErpClient** | ERPNext HTTP API client. Frappe token autentifikatsiya |
| **EpcRegistry** | EPC dedup registri. PostgreSQL UNIQUE constraint bilan soniyasiga 20+ dublikatni filtrlaydi |
| **SettingsStore** | Sozlamalar CRUD. ERP URL, tokenlar (AES shifrlangan), device ID |
| **Realtime** | PubSub broadcast. WebSocket orqali real-time yangilanishlar |
| **CoreHub** | Qurilma registri va command routing |

## Ishga tushirish

### Talablar

- Tavsiya etiladi: Docker (Bridge + PostgreSQL + child runtime'lar bir xil versiyada ishlaydi)
- Lokal (Docker'siz): Elixir 1.16+, PostgreSQL. Child dasturlar uchun qo'shimcha runtime'lar kerak bo'lishi mumkin.

### Tezkor ishga tushirish

```bash
# LCE repo ichidan:
cd LCE
make doctor
make run
```

Bu quyidagilarni qiladi:

1. Extension tanlash so'raydi: **Zebra** yoki **RFID**
2. Telegram bot token so'raydi (birinchi marta) yoki saqlanganni ko'rsatadi
3. PostgreSQL konteynerini ishga tushiradi (agar yo'q bo'lsa)
4. Bridge konteynerini yaratadi va ishga tushiradi
5. Health endpoint tayyor bo'lguncha kutadi
6. Telegram bot'ga config yuboradi (token, URL lar)
7. Terminal'da bridge loglarini real-time ko'rsatadi

`make run` birinchi marta ishlatilganda kerakli child repo yo'q bo'lsa, ularni avtomatik yuklab oladi:

- Zebra: `https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git`
- RFID: `https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git`

Ixtiyoriy: oldindan yuklab olish (internet sekin/offline bo'lsa):

```bash
bash scripts/fetch_children.sh
```

### Child repo'lar (Zebra / RFID)

Bridge child dasturlarni tashqi repo sifatida saqlaydi. Standart joylashuv:

- `zebra_v1/` yoki `ERPNext_Zebra_stabil_enterprise_version/`
- `rfid/` yoki `ERPNext_UHFReader288_integration/`

Eng osoni: `make run` (kerak bo'lsa o'zi yuklab oladi) yoki qo'lda `scripts/fetch_children.sh`.

Qo'lda klon qilish:

```bash
# Tavsiya etiladi (repo nomi bilan klon qiladi):
git clone https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git
git clone https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git

# Legacy papka nomlari bilan:
git clone https://github.com/WIKKIwk/ERPNext_Zebra_stabil_enterprise_version.git zebra_v1
git clone https://github.com/WIKKIwk/ERPNext_UHFReader288_integration.git rfid
```

Nostandart joylashuv bo'lsa:

- `LCE_ZEBRA_HOST_DIR=/path/to/zebra ...`
- `LCE_RFID_HOST_DIR=/path/to/rfid ...`

### Portlar

| Servis | Port | Tavsif |
|--------|------|--------|
| Bridge API | 4000 | HTTP/WebSocket server |
| Zebra Web | 18000 | Zebra printer bridge (C#) |
| RFID Web | 8787 | RFID reader bridge (Java) |
| PostgreSQL | 5432 | Bridge ma'lumotlar bazasi |

### Muhit o'zgaruvchilari

| O'zgaruvchi | Default | Tavsif |
|-------------|---------|--------|
| `LCE_CHILDREN_TARGET` | — | `zebra`, `rfid` yoki `all`. `make run` da tanlanadi |
| `LCE_CHILDREN_MODE` | `on` | `off`/`0`/`false` = child jarayonlar ishga tushmaydi |
| `LCE_SIMULATE_DEVICES` | `1` | `1` = simulyatsiya rejimi (real qurilma yo'q) |
| `LCE_PORT` | `4000` | Bridge HTTP port |
| `LCE_SYNC_INTERVAL_MS` | `10000` | ERPNext sync oraligi (ms) |
| `LCE_SYNC_FULL_EVERY` | `6` | Har nechta siklda to'liq sync (incremental emas) |
| `LCE_RFID_LISTEN_MS` | `1000` | RFID reader polling oraligi (ms) |
| `LCE_RFID_TG_POLL_MS` | `1200` | RFID Telegram bot polling oraligi (ms) |
| `LCE_TG_POLL_MS` | `1200` | Zebra Telegram bot polling oraligi (ms) |
| `TG_TOKEN` | — | Telegram bot token (startup'da kiritiladi) |
| `DATABASE_URL` | `ecto://titan:titan_secret@localhost/titan_bridge_dev` | PostgreSQL ulanish |

## Zebra Bot workflow

Zebra bot — asosiy operator interfeysi. Zavod ishchisi Telegram orqali mahsulotni tortadi, etiket bosadi va ERPNext'da hujjat yaratadi. Bot **batch rejimda** ishlaydi — bir mahsulot va ombor tanlanadi, keyin tarozi → etiket → draft sikli to'xtatilguncha davom etadi.

### Buyruqlar

| Buyruq | Tavsif |
|--------|--------|
| `/start` | Setup wizard: ERP URL → API key (15 belgi) → API secret (15 belgi) |
| `/batch` yoki `/batch start` | Yangi partiya boshlash: mahsulot va ombor tanlash |
| `/batch stop` yoki `/stop` | Joriy partiyani tugatish va sikldan chiqish |
| `/status` | Tizim holati: qurilmalar, ulanishlar |
| `/config` | Joriy sozlamalar (tokenlar yashirilgan) |

### Setup wizard (`/start`)

```
Operator                    Telegram Bot
────────                    ────────────
/start ────────────────────►
                            "ERP manzilini kiriting:"
http://erp.local ──────────►
                            "API KEY kiriting (15 belgi):"
abc123def456ghi ───────────►
                            "API SECRET kiriting (15 belgi):"
jkl789mno012pqr ───────────►
                            Token: "abc123def456ghi:jkl789mno012pqr"
                            AES-GCM bilan shifrlangan holda PostgreSQL ga saqlanadi
                            ERPNext'ga device va session ro'yxatdan o'tkaziladi
                            "Ulandi. /batch buyrug'ini bering."
```

- API key va secret `token api_key:api_secret` formatda birlashtiriladi
- Token `cloak_ecto` orqali AES-GCM shifrlangan holda `lce_settings` jadvaliga yoziladi
- Har bir poll siklida token `SettingsStore` dan o'qiladi — restart kerak emas
- Setup tugagach `ErpClient.upsert_device` va `upsert_session` chaqiriladi

### Partiya jarayoni (batafsil)

```
Operator                    Telegram Bot                  Tizim
────────                    ────────────                  ─────
/batch start ──────────────►
                            ERPNext ping ──────────────── Aloqa tekshirish
                            ◄──────────────────────────── OK

                            [Mahsulot tanlash] ◄───────── Telegram inline query
                            (inline keyboard tugma)        Popup: ERPNext cache
                                                           yoki ERPNext API fallback
Mahsulot tanlaydi ─────────►
(product:ITEM-001)          Mahsulot: ITEM-001
                            [Ombor tanlash] ◄──────────── Inline query: "wh "
                            (inline keyboard tugma)        Faqat zaxira bor omborlar
                                                           (Bin jadvalidan filtr)
Ombor tanlaydi ────────────►
(warehouse:Stores)
                      ┌─────────────── BATCH SIKLI ──────────────┐
                      │                                          │
                      │  begin_weight_flow()                     │
                      │  ├─ Ombordagi zaxira tekshirish          │
                      │  │  └─ 0 bo'lsa: "Mahsulot tugadi" STOP │
                      │  │  └─ <10 bo'lsa: "Diqqat: X qoldi!"   │
                      │  │                                       │
                      │  ├─ CoreHub.command("scale_read")        │
                      │  │  ├─ OK: weight = 12.5                 │
                      │  │  └─ Xato / Simulyatsiya:              │
                      │  │     "Vaznni kiriting (masalan 12.345)" │
                      │  │      Operator kiritadi ──►             │
                      │  │                                       │
                      │  └─ process_print()                      │
                      │     ├─ 1) EPC generatsiya (5 retries)    │
                      │     │    EpcGenerator.next()              │
                      │     │    epc_exists? → bor: retry         │
                      │     │                → yo'q: OK           │
                      │     │                                     │
                      │     ├─ 2) Etiket bosish                  │
                      │     │    CoreHub.command("print_label")   │
                      │     │    payload: epc, product_id,        │
                      │     │      weight_kg, label_fields        │
                      │     │                                     │
                      │     ├─ 3) RFID tag yozish                │
                      │     │    CoreHub.command("rfid_write")    │
                      │     │    payload: {epc: "A1B2..."}        │
                      │     │                                     │
                      │     ├─ 4) ERPNext draft yaratish          │
                      │     │    ErpClient.create_draft()         │
                      │     │    Stock Entry (Material Receipt)   │
                      │     │                                     │
                      │     └─ 5) ERPNext log yozish              │
                      │          ErpClient.create_log()           │
                      │          (Telegram Log doctype)           │
                      │                                          │
                      │  "✓ 12.5 kg | Draft OK"                  │
                      │  "Batch: ITEM-001 → Stores (3 ta)"       │
                      │  "Kutyapman..."                          │
                      │                                          │
                      │  ── 2 soniya kutish ──                   │
                      │  └─ begin_weight_flow() qayta ↑          │
                      └──────────────────────────────────────────┘

/stop ─────────────────────►
                            "Batch tugatildi (ITEM-001).
                             Yangi batch uchun /batch bosing."
```

#### Bosqichma-bosqich:

1. **`/batch start`** — operator yangi partiya boshlaydi
2. **ERPNext ping** — aloqa borligini tekshiradi. Yo'q bo'lsa "Qayta urinish" inline tugmasi chiqadi
3. **Mahsulot tanlash** — Telegram **inline query** orqali. Operator "Mahsulot tanlash" tugmasini bosadi → popup ochiladi → ERPNext cache'dan (`is_stock_item=1`) mahsulotlar ko'rsatiladi. Nomi bo'yicha filtrlash mumkin. Cache'da bo'lmasa ERPNext API'dan to'g'ridan-to'g'ri olinadi. Natija `product:ITEM-001` formatida xabarga yoziladi
4. **Ombor tanlash** — yana inline query orqali. Faqat tanlangan mahsulot uchun zaxira bor omborlar (Bin jadvalidan filtrlangan) ko'rsatiladi. Har bir ombor yonida zaxira miqdori va birlik ko'rsatiladi. Cache'da bo'lmasa `ErpClient.list_warehouses_for_product()` fallback. Natija `warehouse:Stores - T` formatida
5. **Batch sikl boshlanadi** — `begin_weight_flow()` chaqiriladi:
   - **Zaxira tekshirish** — `Cache.warehouses_for_item()` orqali. Agar 0 bo'lsa — "Mahsulot tugadi", batch to'xtatiladi. Agar ≤10 bo'lsa — "Diqqat: X dona qoldi!" ogohlantirish
   - **Tarozi o'qish** — `CoreHub.command("scale_read")` orqali. CoreHub ulanmagan bo'lsa yoki `LCE_SIMULATE_DEVICES=1` bo'lsa — "Vaznni kiriting (masalan 12.345)" so'raladi. Operator qo'lda kg kiritadi
6. **process_print()** — 5 ta bosqich ketma-ket:
   - **EPC generatsiya** — `EpcGenerator.next()` yangi 24-belgili hex EPC yaratadi. `epc_exists?()` ERPNext'dan tekshiradi — bor bo'lsa 5 marta qayta urinadi
   - **Etiket bosish** — `CoreHub.command("print_label")` Zebra printerga yuboradi. Payload: `epc`, `product_id`, `weight_kg`, `label_fields` (nomi, og'irlik, EPC hex)
   - **RFID tag yozish** — `CoreHub.command("rfid_write")` EPC ni RFID tag'ga yozadi
   - **ERPNext draft** — `ErpClient.create_draft()`:
     - `stock_entry_type`: "Material Receipt"
     - `to_warehouse`: tanlangan ombor
     - `items[0].item_code`: tanlangan mahsulot
     - `items[0].qty`: tortilgan og'irlik (kg)
     - `items[0].serial_no`: generatsiya qilingan EPC
     - `items[0].t_warehouse`: tanlangan ombor
   - **ERPNext log** — `ErpClient.create_log()` Telegram Log doctype'ga yoziladi (device_id, action, status, product_id)
7. **Natija** — "✓ 12.5 kg | Draft OK" va "Batch: ITEM-001 → Stores (3 ta)" ko'rsatiladi
8. **Sikl davomi** — 2 soniya kutgandan keyin `begin_weight_flow()` qayta chaqiriladi. Operator keyingi mahsulotni taroziga qo'yishi kutiladi
9. **`/stop`** — batch tugatiladi, vaqtinchalik xabarlar tozalanadi, state "ready" ga qaytadi
10. **ERPNext aloqa uzilsa** — batch avtomatik to'xtatiladi, "Qayta urinish" tugmasi chiqadi

### Simulyatsiya rejimi

`LCE_SIMULATE_DEVICES=1` (default) bo'lganda:
- Tarozi o'qish xatosida → qo'lda vazn kiritish so'raladi (real tarozisiz ishlash)
- Printer xatosida → draft yaratish hali ham davom etadi
- RFID yozish xatosida → draft yaratish hali ham davom etadi

Ishlab chiqarishda `LCE_SIMULATE_DEVICES=0` qo'yiladi — haqiqiy qurilmalar talab qilinadi.

### Zebra Bot state machine

```
                    ┌─────────────────────┐
                    │       idle/none     │
                    │  (bot ishga tushdi) │
                    └──────┬──────────────┘
                           │ /start
                           ▼
              ┌────────────────────────┐
              │   awaiting_erp_url     │
              └────────┬───────────────┘
                       │ URL kiritildi
                       ▼
              ┌────────────────────────┐
              │   awaiting_api_key     │
              └────────┬───────────────┘
                       │ 15 belgili KEY kiritildi
                       ▼
              ┌────────────────────────┐
              │   awaiting_api_secret  │
              └────────┬───────────────┘
                       │ 15 belgili SECRET kiritildi
                       ▼
              ┌────────────────────────┐
              │       ready            │◄───────────────────────┐
              └────────┬───────────────┘                        │
                       │ /batch start                    /stop  │
                       ▼                                        │
              ┌────────────────────────┐                        │
              │   awaiting_warehouse   │  (mahsulot tanlangandan │
              │   (inline query)       │   keyin)               │
              └────────┬───────────────┘                        │
                       │ ombor tanlandi                         │
                       ▼                                        │
              ┌────────────────────────┐                        │
              │       batch            │────────────────────────┘
              │  (sikl: tarozi →       │   Ombor tugasa →
              │   etiket → draft →     │   ERPNext uzilsa →
              │   2s → tarozi → ...)   │
              │                        │
              │   awaiting_weight      │  (tarozi yo'q bo'lsa)
              └────────────────────────┘
```

## RFID Bot workflow

RFID bot — UHF RFID reader bilan ishlaydi. Reader tag o'qiganda, EPC kodni ERPNext draftlari bilan solishtiradi va mos kelsa avtomatik submit qiladi.

### Buyruqlar

| Buyruq | Tavsif |
|--------|--------|
| `/start` | Setup wizard: ERP URL, API key, API secret kiritish |
| `/scan` | RFID reader'ni ishga tushiradi va tag kutishni boshlaydi |
| `/stop` | Reader'ni to'xtatadi va scanning rejimidan chiqadi |
| `/status` | Bot holati, ERPNext aloqa, reader holati, submit soni |
| `/list` | ERPNext'dagi EPC li draft'lar ro'yxati (nomi, mahsulot, EPC) |
| `/cache` | Lokal cache hisoboti — `.log` fayl sifatida yuboriladi |
| `/report` | O'qilgan EPC lar hisoboti — `.log` fayl sifatida yuboriladi |

### Skanerlash jarayoni (batafsil)

```
Operator          RFID Bot           RfidListener       RFID Server (Java)
────────          ────────           ────────────       ──────────────────
/scan ───────────►
                  ERPNext ping ─────► (aloqa tekshirish)
                  ◄──────────────────  OK

                  inventory/start ──────────────────────► Reader o'qiy boshlaydi
                  ◄──────────────────────────────────────  OK

                  RfidListener.subscribe(self()) ──────►

                  "RFID skaner
                   ishlayapti!" ────► Operator ko'radi

                                      Har 1 soniyada:
                                      GET /api/status ──► {lastTag: {epcId: "A1B2..."}}

                                      Yangi EPC topilsa:
                                      {:rfid_tag, epc} ──►

                  handle_tag_scan(epc)
                  │
                  ├─ EpcRegistry.register_once(epc)
                  │  ├─ {:ok, :exists} ──► SKIP (dublikat, 20+/sek)
                  │  └─ {:ok, :new} ──► davom etadi ▼
                  │
                  ├─ Cache.find_draft_by_epc(epc)     ◄── 1) Lokal ETS cache (bir zumda)
                  │  ├─ {:ok, draft_info} ──► topildi!
                  │  └─ :not_found ──►
                  │     ErpClient.find_draft_by_serial_no(epc) ◄── 2) ERPNext fallback
                  │     ├─ {:ok, doc} ──► topildi!
                  │     └─ :not_found ──► EPC hech qayerda yo'q
                  │
                  ├─ Topilsa:
                  │  ErpClient.submit_stock_entry(name) ──► PUT docstatus=1
                  │  EpcRegistry.mark_submitted(epc)
                  │  Cache.delete_epc_mapping(epc)
                  │
                  │  "MAT-STE-00042 submitted!
                  │   hotlunch002: 12.5
                  │   EPC: A1B2C3D4E5F6..." ──► Operator ko'radi
                  │
                  └─ Topilmasa: hech narsa qilmaydi (tag draft'da yo'q)

/stop ───────────►
                  RfidListener.unsubscribe(self())
                  inventory/stop ───────────────────────► Reader to'xtaydi
                  "Skaner to'xtatildi.
                   3 ta draft submit
                   qilindi." ──────► Operator ko'radi
```

#### Bosqichma-bosqich:

1. **`/scan`** bosiladi
2. **ERPNext ping** — aloqa borligini tekshiradi. Yo'q bo'lsa "Qayta urinish" tugmasi chiqadi
3. **RFID inventory start** — Java server'ga `POST /api/inventory/start` yuboriladi. Reader antennani yoqadi va tag o'qishni boshlaydi
4. **RfidListener subscribe** — bot RFID tag event'lariga obuna bo'ladi
5. **Tag o'qiladi** — RFID reader UHF tag'ni o'qiydi. Java server `lastTag.epcId` ga yozadi
6. **RfidListener polling** — har 1 soniyada `GET /api/status` so'raydi. Yangi EPC bo'lsa `{:rfid_tag, epc}` xabar yuboradi
7. **Dublikat filtr** — `EpcRegistry.register_once(epc)`:
   - Reader bitta tag'ni soniyasiga 20+ marta o'qishi mumkin
   - Faqat birinchi marta ko'rilgan EPC PostgreSQL'ga yoziladi (`UNIQUE` constraint)
   - Dublikatlar `{:ok, :exists}` bilan qaytadi — hech narsa qilinmaydi
8. **Gibrid qidirish** (yangi EPC uchun):
   - **1-qadam: Lokal cache** — `Cache.find_draft_by_epc(epc)` ETS jadvalidan bir zumda tekshiradi
   - **2-qadam: ERPNext fallback** — lokal cache'da topilmasa, `ErpClient.find_draft_by_serial_no(epc)` orqali ERPNext'dan qidiriladi. Bu `Stock Entry Detail` child jadvalidan `serial_no LIKE %epc%` va `docstatus=0` (draft) filtr bilan qidiradi
9. **Auto-submit** — mos draft topilsa:
   - `ErpClient.submit_stock_entry(name)` — ERPNext'ga `PUT` so'rov, `docstatus: 1` (Submitted)
   - `EpcRegistry.mark_submitted(epc)` — PostgreSQL'da status "submitted" ga o'zgartiriladi
   - `Cache.delete_epc_mapping(epc)` — ETS cache'dan olib tashlanadi (qayta submit bo'lmasin)
   - Telegram'ga natija yuboriladi: draft nomi, mahsulot, miqdor, EPC
10. **`/stop`** — reader to'xtatiladi, obuna bekor qilinadi, submit soni ko'rsatiladi

### Gibrid cache tizimi

ErpSyncWorker har 10 soniyada ERPNext'dan draft'larni sync qiladi va lokal EPC mapping yaratadi:

```
ErpSyncWorker (har 10 sek)
│
├─ sync_stock_drafts()
│  ERPNext ──► PostgreSQL (lce_stock_drafts)
│          ──► ETS (:lce_cache_stock_drafts)
│
└─ build_epc_draft_mapping()
   Har bir draft uchun:
   ├─ draft.data["items"] bormi? ──► bor: ishlatadi
   └─ yo'q: ERPNext'dan get_doc() ──► data field'ini yangilaydi

   Har bir item.serial_no (EPC):
   ├─ normalize_epc(serial_no)
   └─ ETS: {epc => %{name: "SE-001", doc: full_doc}}

   Natija: :lce_cache_epc_drafts ETS jadvali
   Tezlik: < 1ms (tarmoqsiz, ETS lookup)
```

Bu gibrid yondashuv ikkita afzallik beradi:
- **Tezlik**: Ko'p hollarda EPC lokal cache'dan topiladi (< 1ms), ERPNext'ga murojaat kerak emas
- **Yangilik**: Cache'da bo'lmagan yangi draft'lar ERPNext'dan fallback bilan topiladi

### `/cache` buyruqi

`.log` fayl sifatida Telegram'ga yuboriladi. Tarkibi:

```
============================================
  RFID BOT — LOKAL CACHE HISOBOTI
  Sana: 2026-02-07 14:30:00
  Jami draftlar: 3
============================================

-------- Draft #1 --------
  Nomi:      MAT-STE-00042
  Status:    0
  Maqsad:    Material Receipt
  Sana:      2026-02-07 14:20:00
  Ombor:     Stores - T
  O'zgargan: 2026-02-07 14:20:00
  Items:
    1. hotlunch002 | qty: 12.5 | EPC: A1B2C3D4E5F60001

============================================
  EPC → DRAFT MAPPING (3 ta)
============================================

  A1B2C3D4E5F60001 → MAT-STE-00042
  A1B2C3D4E5F60002 → MAT-STE-00043
  A1B2C3D4E5F60003 → MAT-STE-00044
```

### `/report` buyruqi

`.log` fayl sifatida Telegram'ga yuboriladi. Tarkibi:

```
============================================
  RFID BOT — O'QILGAN EPC HISOBOTI
  Sana: 2026-02-07 14:35:00
  Jami uniq EPC: 5
  Skan qilingan: 3
  Submit qilingan: 2
============================================

     1. [OK] A1B2C3D4E5F60001  |  submitted  |  2026-02-07 14:25:00
     2. [OK] A1B2C3D4E5F60002  |  submitted  |  2026-02-07 14:26:00
     3. [--] A1B2C3D4E5F60003  |  scanned    |  2026-02-07 14:27:00
     4. [--] DEADBEEF12345678  |  scanned    |  2026-02-07 14:28:00
     5. [--] 1122334455667788  |  scanned    |  2026-02-07 14:29:00
```

- `[OK]` — EPC mos draft topildi va submit qilindi
- `[--]` — EPC o'qildi lekin mos draft topilmadi

## EPC Registry (dedup tizimi)

RFID reader bitta tag'ni soniyasiga 20+ marta o'qishi mumkin. Har bir o'qishda tarmoqqa murojaat qilish juda qimmat. Shuning uchun `EpcRegistry` ikki bosqichli dedup qiladi:

1. **ETS tekshiruv** (< 1ms) — `EpcRegistry.exists?(epc)` PostgreSQL'dan o'qiydi
2. **PostgreSQL INSERT** — `on_conflict: :nothing` bilan yozadi. `UNIQUE` constraint dublikatni rad etadi

```
Tag o'qildi: "A1B2C3D4"
│
├─ EpcRegistry.register_once("A1B2C3D4")
│  ├─ exists?() → true  ──► {:ok, :exists} (SKIP)
│  └─ exists?() → false ──► INSERT ... ON CONFLICT DO NOTHING
│     ├─ success ──► {:ok, :new} (yangi EPC!)
│     └─ conflict ──► {:ok, :exists} (boshqa process birinchi bo'ldi)
```

### PostgreSQL jadvali: `lce_epc_registry`

| Ustun | Tur | Tavsif |
|-------|-----|--------|
| `epc` | string, PK | Normalizatsiya qilingan EPC (faqat 0-9, A-F) |
| `source` | string | "rfid" yoki "bridge" |
| `status` | string | "scanned" (o'qildi), "submitted" (draft submit qilindi), "reserved" (Zebra bot) |
| `inserted_at` | datetime | Birinchi marta ko'rilgan vaqt |
| `updated_at` | datetime | Oxirgi yangilangan vaqt |

### EPC normalizatsiya

Barcha EPC kodlar bir xil formatga keltiriladi:
```
"a1:b2:c3:d4" → "A1B2C3D4"
" A1-B2-C3 "  → "A1B2C3"
"a1b2c3d4"    → "A1B2C3D4"
```

Qoida: `trim → upcase → faqat 0-9 va A-F belgilan qoldirish`

## ERPNext integratsiya

### Autentifikatsiya

Frappe token-based auth: `Authorization: token api_key:api_secret`

Setup wizard orqali kiritiladi:
1. ERP URL (masalan: `http://erp.factory.local`)
2. API key (15 belgili alfanumerik)
3. API secret (15 belgili alfanumerik)

Token AES-GCM bilan shifrlangan holda PostgreSQL'da saqlanadi (`cloak_ecto`).

### API chaqiruvlar

| Operatsiya | Method | Endpoint | Tavsif |
|------------|--------|----------|--------|
| Ping | GET | `/api/method/frappe.ping` | Aloqa tekshirish |
| Items ro'yxati | GET | `/api/resource/Item` | Mahsulotlar (is_stock_item=1) |
| Warehouses | GET | `/api/resource/Warehouse` | Omborlar |
| Bins | GET | `/api/resource/Bin` | Zaxira darajalari (item + warehouse) |
| Stock Entry drafts | GET | `/api/resource/Stock Entry` | Draftlar (docstatus=0) |
| Doc olish | GET | `/api/resource/{doctype}/{name}` | To'liq hujjat (items bilan) |
| Draft yaratish | POST | `/api/resource/Stock Entry` | Material Receipt draft |
| Draft submit | PUT | `/api/resource/Stock Entry/{name}` | `docstatus: 1` (Submitted) |
| Serial no qidirish | GET | `/api/resource/Stock Entry Detail` | `serial_no LIKE %epc%`, `docstatus=0` |

### Sync jarayoni (ErpSyncWorker)

Har 10 soniyada:
1. **Items** — `modified > last_sync` filtr bilan yangilangan mahsulotlar
2. **Warehouses** — yangilangan omborlar
3. **Bins** — yangilangan zaxira darajalari
4. **Stock Drafts** — yangilangan draft Stock Entry'lar
5. **EPC mapping** — draft'lardan `serial_no` → EPC mapping yaratiladi

Har 6-siklda (1 daqiqa) to'liq sync — o'chirilgan draft'lar ham tozalanadi.

Ma'lumotlar 3 joyda saqlanadi:
- **ETS** — tezkor in-memory cache (read uchun)
- **PostgreSQL** — doimiy saqlash (restart'dan keyin ETS'ga yuklanadi)
- **ERPNext** — asosiy manba (master data)

## Ma'lumotlar bazasi

### Jadvallar

| Jadval | Tavsif |
|--------|--------|
| `lce_settings` | Singleton sozlamalar (id=1). ERP URL, tokenlar (shifrlangan), device ID |
| `lce_items` | ERPNext mahsulotlar cache (name, item_name, stock_uom, disabled) |
| `lce_warehouses` | ERPNext omborlar cache (name, warehouse_name, is_group, disabled) |
| `lce_bins` | Zaxira darajalari cache (item_code + warehouse = PK, actual_qty) |
| `lce_stock_drafts` | Stock Entry draftlar cache (name = PK, docstatus, purpose, data) |
| `lce_epc_registry` | EPC dedup registri (epc = PK, source, status) |
| `lce_epc_sequences` | EPC generatsiya ketma-ketligi |

### Migratsiyalar

```
20260205190000_create_settings.exs       — lce_settings jadvali
20260205190500_create_epc_sequences.exs  — lce_epc_sequences jadvali
20260206120000_create_cache_tables.exs   — items, warehouses, bins, stock_drafts, epc_registry
20260207080000_encrypt_token_fields.exs  — token ustunlarini text → bytea (AES)
20260207120000_add_rfid_telegram_token.exs — rfid_telegram_token ustuni
```

## ETS jadvallar (in-memory cache)

| Jadval | Kalit | Qiymat | Tavsif |
|--------|-------|--------|--------|
| `:lce_cache_items` | `name` | item map | Mahsulotlar |
| `:lce_cache_warehouses` | `name` | warehouse map | Omborlar |
| `:lce_cache_bins` | `{item_code, warehouse}` | bin map | Zaxira darajalari |
| `:lce_cache_stock_drafts` | `name` | draft map | Stock Entry draftlar |
| `:lce_cache_epc_drafts` | `normalized_epc` | `%{name, doc}` | EPC → draft mapping |
| `:lce_cache_meta` | `{entity, :version}` | integer | Cache versiya raqami |
| `:tg_state` | `chat_id` | state string | Zebra bot chat holati |
| `:tg_temp` | `{chat_id, key}` | qiymat | Zebra bot vaqtinchalik ma'lumot |
| `:rfid_tg_state` | `chat_id` | state string | RFID bot chat holati |
| `:rfid_tg_temp` | `{chat_id, key}` | qiymat | RFID bot vaqtinchalik ma'lumot |

## Supervision tree

```
TitanBridge.Supervisor (one_for_one)
├── TitanBridge.Vault           — AES-GCM shifrlash kaliti
├── TitanBridge.Repo            — PostgreSQL Ecto pool
├── Finch (TitanBridgeFinch)    — HTTP client pool
├── TitanBridge.Realtime        — PubSub broadcast
├── TitanBridge.CoreHub         — Qurilma registri
├── TitanBridge.ErpSyncWorker   — ERPNext sync (10 sek)
├── TitanBridge.Children        — OS jarayon menejeri (zebra/rfid)
├── TitanBridge.Telegram.Bot    — Zebra Telegram bot
├── TitanBridge.RfidListener    — RFID tag polling (1 sek)
├── TitanBridge.Telegram.RfidBot — RFID Telegram bot
└── Plug.Cowboy                 — HTTP server (:4000)
```

## Children (OS jarayon menejeri)

Bridge ikki tashqi dasturni Port orqali boshqaradi:

### Zebra (C# / .NET)
- **Vazifa**: Zebra printer bilan aloqa, etiket bosish
- **Ishga tushirish**: `bash run.sh` (`zebra_v1/` papkada)
- **Port**: 18000
- **Muhit**: `ZEBRA_WEB_HOST`, `ZEBRA_WEB_PORT`, `ZEBRA_NO_TUI=1`

### RFID (Java)
- **Vazifa**: UHF RFID reader bilan aloqa, tag o'qish
- **Ishga tushirish**: `bash start-web.sh` (`rfid/` papkada)
- **Port**: 8787
- **Muhit**: `HOST`, `PORT`, `SKIP_BUILD_BRIDGE=1`, `RFID_NO_TUI=1`
- **API endpointlar**:
  - `GET /api/status` — reader holati, oxirgi o'qilgan tag (`lastTag.epcId`)
  - `POST /api/inventory/start` — tag o'qishni boshlash (antenna yoqiladi)
  - `POST /api/inventory/stop` — tag o'qishni to'xtatish

### LCE_CHILDREN_TARGET

Qaysi child jarayonlar ishga tushishini boshqaradi:

| Qiymat | Natija |
|--------|--------|
| `zebra` | Faqat Zebra child ishga tushadi |
| `rfid` | Faqat RFID child ishga tushadi |
| `all` | Ikkalasi ham ishga tushadi |
| `zebra,rfid` | Ikkalasi ham (vergul bilan ajratilgan) |

`make run` da interaktiv tanlanadi. Docker konteynerga muhit o'zgaruvchisi sifatida uzatiladi.

### Auto-restart

Child jarayon kutilmaganda to'xtasa, 1.5 soniyadan keyin qayta ishga tushiriladi (backoff). Logda `[child zebra] exited with status N` ko'rinadi.

## Docker konfiguratsiya

### Konteynerlar

| Konteyner | Image | Vazifa |
|-----------|-------|--------|
| `lce-bridge-dev` | `hexpm/elixir:1.16.2-erlang-26.2.5-debian-bookworm` | Bridge (Elixir) |
| `lce-postgres-dev` | `postgres:16-alpine` | Bridge PostgreSQL |
| `lce-core-cache-db` | `postgres:16-alpine` | Core cache PostgreSQL |

### Docker tarmoq

Barcha konteynerlar `lce-bridge-net` Docker network'ida ishlaydi. Bridge konteyner PostgreSQL'ga container nomi orqali ulanadi (`lce-postgres-dev:5432`).

### Volume mount'lar

| Host yo'li | Container yo'li | Tavsif |
|------------|-----------------|--------|
| `LCE/src/bridge/` | `/app` | Bridge source kodi (live reload) |
| `.cache/lce-build/` | `/app/_build` | Elixir build cache |
| `.cache/lce-deps/` | `/app/deps` | Elixir deps cache |
| `.cache/lce-mix/` | `/root/.mix` | Mix arxivlari (hex, rebar) |
| `zebra_v1/` | `/zebra_v1` | Zebra child dastur |
| `rfid/` | `/rfid` | RFID child dastur |

### Build cache

- Bridge source kodi o'zgarganda `_build` avtomatik tozalanadi (marker fayl orqali)
- `deps` cache saqlanadi (faqat `mix.exs` o'zgarganda yangilanadi)
- Mix arxivlari (hex, rebar) saqlanadi

## HTTP API

Bridge `http://localhost:4000` da HTTP server ishga tushiradi.

| Endpoint | Method | Tavsif |
|----------|--------|--------|
| `/api/health` | GET | Health check (`{"status": "ok"}`) |
| `/api/status` | GET | Tizim holati |
| `/api/config` | GET | Joriy sozlamalar (tokenlar masked) |
| `/api/config` | POST | Sozlamalar yangilash (JSON body) |
| `/ws/core` | WS | Core device WebSocket |

## Fayl tuzilishi

```
LCE/src/bridge/
├── config/
│   ├── config.exs              — Compile-time config
│   └── runtime.exs             — Runtime config (env vars, children)
├── lib/
│   └── titan_bridge/
│       ├── application.ex      — OTP Application, supervision tree
│       ├── cache.ex            — ETS cache manager
│       ├── cache/
│       │   ├── item.ex         — Item Ecto schema
│       │   ├── warehouse.ex    — Warehouse Ecto schema
│       │   ├── bin.ex          — Bin Ecto schema
│       │   ├── stock_draft.ex  — StockDraft Ecto schema
│       │   └── epc_registry.ex — EpcRegistry Ecto schema (dedup)
│       ├── children.ex         — OS process manager (Port)
│       ├── core_hub.ex         — Device registry + command routing
│       ├── epc_generator.ex    — EPC kod generatsiya
│       ├── epc_registry.ex     — EPC dedup (register_once, mark_submitted)
│       ├── erp_client.ex       — ERPNext HTTP API client
│       ├── erp_sync_worker.ex  — Periodic ERPNext sync + EPC mapping
│       ├── realtime.ex         — PubSub broadcast
│       ├── repo.ex             — Ecto Repo
│       ├── rfid_listener.ex    — RFID tag polling (1s)
│       ├── settings.ex         — Settings Ecto schema (AES encrypted)
│       ├── settings_store.ex   — Settings CRUD wrapper
│       ├── telegram_bot.ex     — Zebra Telegram bot
│       ├── telegram/
│       │   └── rfid_bot.ex     — RFID Telegram bot
│       ├── vault.ex            — Cloak AES-GCM vault
│       ├── encrypted/
│       │   └── binary.ex       — Cloak encrypted binary type
│       └── web/
│           ├── router.ex       — Plug router
│           └── core_socket.ex  — WebSocket handler
├── priv/
│   └── repo/
│       └── migrations/         — Ecto migratsiyalar
├── mix.exs                     — Loyiha konfiguratsiya va deps
└── mix.lock                    — Deps versiya lock
```

## Dependencies

| Paket | Versiya | Vazifa |
|-------|---------|--------|
| `plug_cowboy` | ~> 2.6 | HTTP/WebSocket server |
| `jason` | ~> 1.4 | JSON encoder/decoder |
| `ecto_sql` | ~> 3.11 | PostgreSQL ORM |
| `postgrex` | >= 0.0.0 | PostgreSQL driver |
| `finch` | ~> 0.18 | HTTP client (ERPNext, Telegram API) |
| `cloak_ecto` | ~> 1.3 | AES-GCM shifrlash (tokenlar uchun) |

## To'liq oqim: Zebra etiketdan RFID submit'gacha

```
1. ZEBRA BOT                              2. RFID BOT
   ──────────                                ──────────
   /batch start                              /scan
   ↓                                         ↓
   Mahsulot tanlash                          RFID reader yoqiladi
   ↓                                         ↓
   Ombor tanlash                             Tag o'qiy boshlaydi
   ↓                                         ↓
   Tarozi tortish (12.5 kg)                  EPC: A1B2C3D4E5F60001
   ↓                                         ↓
   Zebra etiket bosish                       EpcRegistry dedup
   (EPC: A1B2C3D4E5F60001)                  ↓
   ↓                                         Lokal cache qidirish
   ERPNext'da draft yaratish                 ↓ (yoki ERPNext fallback)
   MAT-STE-00042                             Draft topildi: MAT-STE-00042
   docstatus: 0 (Draft)                      ↓
   items[0].serial_no =                      submit_stock_entry("MAT-STE-00042")
     "A1B2C3D4E5F60001"                      ↓
                                             ERPNext: docstatus → 1 (Submitted)
                                             ↓
                                             "MAT-STE-00042 submitted!"
```

## RFID Bot state machine

```
                    ┌─────────────────────┐
                    │       idle          │
                    │  (bot ishga tushdi) │
                    └──────┬──────────────┘
                           │
                    /start │
                           ▼
              ┌────────────────────────┐
              │   awaiting_erp_url     │
              │  "ERP manzilini        │
              │   kiriting:"           │
              └────────┬───────────────┘
                       │ URL kiritildi
                       ▼
              ┌────────────────────────┐
              │   awaiting_api_key     │
              │  "API KEY kiriting     │
              │   (15 belgi):"         │
              └────────┬───────────────┘
                       │ KEY kiritildi
                       ▼
              ┌────────────────────────┐
              │   awaiting_api_secret  │
              │  "API SECRET kiriting  │
              │   (15 belgi):"         │
              └────────┬───────────────┘
                       │ SECRET kiritildi
                       ▼
              ┌────────────────────────┐
              │       ready            │◄──────────┐
              │  "Ulandi!"             │           │
              │  /scan, /list, /status │           │
              └────────┬───────────────┘           │
                       │                           │
                /scan  │                    /stop  │
                       ▼                           │
              ┌────────────────────────┐           │
              │      scanning          │───────────┘
              │  RFID reader ishlayapti│
              │  Tag → dedup → search  │
              │  → submit              │
              │  ERPNext aloqa uzilsa → │───────────┘
              │  avtomatik to'xtaydi   │
              └────────────────────────┘
```
