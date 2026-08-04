# S-FUNC — Live-environment functional suite (ADR-0045)

**Purpose:** Exercise a **deployed** SlotSense env (HTTPS, Firebase Auth, Firestore,
Redis, Vertex) so env-wiring and critical journeys fail closed before cutover.

## Run

```bash
./scripts/run_functional.sh              # interactive prompts + defaults
./scripts/run_functional.sh --yes        # env / .env.local only
./scripts/run_functional.sh -k catalog   # pytest filter
```

## Cases

| File | Coverage |
|---|---|
| `test_smoke_and_spa.py` | Health, build meta, TLS, SPA `projectId` + `VITE_BASE_DOMAIN` |
| `test_booking_and_redis.py` | Facilities, availability, horizon, Redis ≠ LOCK_UNAVAILABLE |
| `test_booking_lifecycle.py` | Book → list mine → cancel |
| `test_concurrency.py` | N parallel book → exactly one 201 |
| `test_host_and_agent.py` | Host isolation, agent/Vertex not fallback-only |
| `test_users_me.py` | Authenticated profile |
| `test_platform_catalog.py` | Platform catalog create/patch/delete |
| `test_tenant_provision.py` | Create tenant + user, temp 6-digit, force password, delete tenant |
| `test_daily_overview_invoices.py` | Tenant admin overview; resident invoices/mine |
| `test_voice.py` | Voice endpoint smoke (optional fixture) |

## Credentials

| Env | Used by |
|---|---|
| Resident | Most tenant tests |
| Platform admin | Catalog + tenant provision |
| Tenant admin | Daily overview |

Mutating tests skip if `FUNC_SKIP_MUTATIONS=1` or platform admin not set.

## Env wiring failures this suite detects

| Incident | Test |
|---|---|
| Missing `VITE_BASE_DOMAIN` | SPA embed |
| Wrong Firebase project | SPA projectId |
| Redis AUTH mismatch | booking LOCK_UNAVAILABLE |
| Vertex disabled | agent safe-fallback |
| Horizon misapplied | availability horizon |

## Not Playwright

Browser UI E2E remains a separate backlog item. This pack is API + SPA scrape.

## CI later

`workflow_dispatch` on GitHub Environment `test` with secrets — not every PR.
