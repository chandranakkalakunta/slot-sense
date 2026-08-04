# R2 — Product regression pack (from S-FUNC)

**Status:** Seed list extracted from live S-FUNC (2026-08)  
**ADR:** [0045](../adr/0045-test-strategy-and-environment-promotion.md)

Stable cases to re-run after risky changes (auth, booking, multi-env, agent).
Prefer automated `./scripts/run_functional.sh`; use this as the checklist name.

| ID | Case | Automated |
|---|---|---|
| R2-01 | Health + build_id/deployed_at on admin host | `test_smoke_and_spa` |
| R2-02 | SPA embeds projectId + VITE_BASE_DOMAIN | `test_smoke_and_spa` |
| R2-03 | Tenant host TLS + /health | `test_smoke_and_spa` |
| R2-04 | Facilities list + availability slots | `test_booking_and_redis` |
| R2-05 | Horizon far-date BEYOND_HORIZON | `test_booking_and_redis` |
| R2-06 | Book not LOCK_UNAVAILABLE | `test_booking_and_redis` |
| R2-07 | Book → mine → cancel | `test_booking_lifecycle` |
| R2-08 | Concurrency N→1×201 | `test_concurrency` |
| R2-09 | Wrong tenant host TENANT_MISMATCH | `test_host_and_agent` |
| R2-10 | Agent not Vertex fallback-only | `test_host_and_agent` |
| R2-11 | Agent propose/confirm | `test_agent_propose_confirm` |
| R2-12 | Catalog CRUD | `test_platform_catalog` |
| R2-13 | Tenant provision + force password | `test_tenant_provision` |
| R2-14 | Daily overview RBAC | `test_daily_overview_invoices` |
| R2-15 | Invoice admin latest/export/regenerate | `test_invoices_admin` |
| R2-16 | Health latency sample | `test_latency` |
| R2-17 | Browser sign-in + facilities | `tests/e2e` Playwright |

**When:** before prod promote; after multi-env/DNS/auth/booking/agent changes.
