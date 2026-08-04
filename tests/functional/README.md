# S-FUNC — Live-environment functional suite (ADR-0045)

**Purpose:** Exercise a **deployed** SlotSense env so env-wiring and critical
journeys fail closed before cutover / next phase.

## Run

```bash
./scripts/run_functional.sh              # interactive
./scripts/run_functional.sh --yes        # from .env.local
./scripts/run_functional.sh -k 'invoice or agent'
```

**CI:** Actions → **Functional (S-FUNC)** → Run workflow (needs secrets).

**Browser E2E:** `tests/e2e/` (Playwright) — see that README.  
**R2 checklist:** `docs/testing/R2-REGRESSION-PACK.md`

## Cases (~30+ tests)

| File | Coverage |
|---|---|
| `test_smoke_and_spa.py` | Health, build meta, TLS, SPA embeds |
| `test_booking_and_redis.py` | Facilities, horizon, Redis lock |
| `test_booking_lifecycle.py` | Book → mine → cancel |
| `test_concurrency.py` | N parallel → one 201 |
| `test_latency.py` | Health p50/p95 sample |
| `test_host_and_agent.py` | Host isolation, Vertex not fallback |
| `test_agent_propose_confirm.py` | Propose book + confirm |
| `test_users_me.py` | Profile |
| `test_platform_catalog.py` | Catalog CRUD |
| `test_tenant_provision.py` | Tenant + 6-digit + force password |
| `test_daily_overview_invoices.py` | Overview RBAC, invoices/mine |
| `test_invoices_admin.py` | Latest, export, regenerate, RBAC |
| `test_voice.py` | Voice smoke (optional) |

## Credentials

| Role | Env vars |
|---|---|
| Resident | `FUNC_RESIDENT_*` (required) |
| Platform admin | `FUNC_PLATFORM_ADMIN_*` (catalog / tenant create) |
| Tenant admin | `FUNC_TENANT_ADMIN_*` (overview / invoice admin) |

## Skips

`FUNC_SKIP_AGENT`, `FUNC_SKIP_BOOKING`, `FUNC_SKIP_MUTATIONS`,
`FUNC_SKIP_CONCURRENCY`, `FUNC_SKIP_VOICE`
