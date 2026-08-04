# S-FUNC — Live-environment functional suite (ADR-0045)

**Purpose:** Exercise **deployed** SlotSense the way operators and residents do —
HTTPS, real Firebase Auth, real Firestore/Redis/Vertex — so env-wiring bugs
surface before humans find them in production cutovers.

**Not for:** PR hermetic CI (that remains `backend/tests` + `frontend` vitest).  
**Regression suite:** later; extract stable cases from this pack into R2.

## What this suite would have caught (2026-08 test-03)

| Incident | Case |
|---|---|
| SPA missing `VITE_BASE_DOMAIN` → no tenant redirect / wrong apex | `test_spa_embeds_base_domain` |
| SPA wrong Firebase `projectId` | `test_spa_embeds_firebase_project_id` |
| Redis AUTH secret mismatch → booking 503 `LOCK_UNAVAILABLE` | `test_booking_create_not_lock_unavailable` |
| Vertex AI API disabled → agent safe-fallback | `test_agent_query_not_vertex_disabled` |
| Health / deploy identity | `test_health_has_build_meta` |
| Horizon / window policy applied | `test_availability_horizon_respects_policy` |
| Host ↔ tenant isolation | `test_wrong_tenant_host_rejected` |

## Prerequisites

1. Target env is **deployed** (e.g. `slot-sense-test-03` + DNS + cert ACTIVE).  
2. Seeded users:
   - Platform admin (optional for catalog tests later)
   - Resident (or tenant_admin) on a **real tenant slug** with at least one **active facility** and schedule covering the test date  
3. Credentials via env (never commit):

```bash
cp tests/functional/.env.example tests/functional/.env.local
# edit .env.local — source it or export vars
```

## Run

```bash
# Interactive (prompts with defaults; can save .env.local)
./scripts/run_functional.sh

# Non-interactive (must source env first)
set -a && source tests/functional/.env.local && set +a
./scripts/run_functional.sh --yes

# Filter
./scripts/run_functional.sh -k 'spa or health'
```

Firebase API key default is loaded from
`infrastructure/firebase-web-configs/<FUNC_PROJECT_ID>.json` when present.

**Against test-03 defaults** (override with env):

| Variable | Example |
|---|---|
| `FUNC_BASE_DOMAIN` | `slotsense-test.chandraailabs.com` |
| `FUNC_ADMIN_HOST` | `admin.slotsense-test.chandraailabs.com` |
| `FUNC_TENANT_SLUG` | `marina-skies` |
| `FUNC_PROJECT_ID` | `slot-sense-test-03` |
| `FUNC_FIREBASE_API_KEY` | from `infrastructure/firebase-web-configs/<project>.json` |
| `FUNC_RESIDENT_EMAIL` / `FUNC_RESIDENT_PASSWORD` | seeded resident |
| `FUNC_FACILITY_ID` | optional; auto-picked from `GET /facilities` if empty |

## Markers / skip policy

- Tests that need credentials **skip** with a clear reason if env is missing.  
- Public checks (health, SPA static scrape) always run when `FUNC_BASE_DOMAIN` is set.  
- Agent test skips if `FUNC_SKIP_AGENT=1`.  
- Booking mutate tests skip if `FUNC_SKIP_BOOKING=1` (read-only CI).

## More cases (backlog — not yet automated)

| ID | Case | Why |
|---|---|---|
| F-P1 | Platform admin catalog CRUD | Needs platform_admin credentials |
| F-P2 | Create tenant + tenant_admin + 6-digit | Mutates registry; needs admin + cleanup |
| F-P3 | Resident force-password path | Needs fresh seed user |
| F-P4 | Book → cancel full lifecycle assert | Partial (create+cancel best-effort today) |
| F-P5 | Daily overview / invoices | Tenant admin + data |
| F-P6 | Voice STT/TTS turn | Audio fixture + Speech API |
| F-P7 | Playwright UI (sign-in, book click) | Browser E2E |
| F-P8 | Concurrency N parallel book → 1×201 | Wraps `scripts/concurrency_test.py` |
| F-P9 | SPA redirect on admin after resident login | Needs browser or soft assert |

## CI later

Wire as a **workflow_dispatch** / post-promote job on GitHub Environment `test`
with secrets for resident credentials — not on every PR (ADR-0045 D3).
