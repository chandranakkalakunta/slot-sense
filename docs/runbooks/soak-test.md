# Soak / load test — test environment

**Audience:** Coordinator  
**Env:** `slot-sense-test-03` only (script refuses non-test projects unless overridden)  
**Script:** `scripts/soak_test.py`  
**Seed prerequisite:** [seed-test-population.md](./seed-test-population.md)  
**Observability:** [observability.md](./observability.md)

## Goals

| # | Goal | How the harness does it |
|---|------|-------------------------|
| 1 | Real traffic mix | Steady workers: **availability**, **book**, **list mine**, **cancel**, facility list |
| 2 | ≥10–15% tenants active | `--tenant-pct 15` samples that share of seeded tenants |
| 3 | 08:00 morning stress | `--rush-at 08:00` (Asia/Kolkata) or `--rush-now` for immediate flash |
| 4 | Watch monitoring live | Ops dashboard + Cloud Run metrics open during run (below) |
| 5 | Lock correctness under load | Periodic **N-parallel same-slot** waves (expect 1 winner) |

### Additional scenarios included

| Scenario | Intent |
|----------|--------|
| **Cancel churn** | Book then later cancel — free slots, exercise cancel path + notifications/tasks |
| **Multi-day scatter** | Book across next 1–6 days (horizon realism) |
| **Read-heavy mix** | ~40% availability-only ticks (cache/Firestore read path) |
| **Per-tenant rush** | Flash contention is **per tenant facility** (multi-tenant isolation under load) |
| **Lock proof waves** | Every N ticks, classic concurrency proof on busiest tenant |
| **Auth pool** | Many real Firebase ID tokens (not one token reused only) |

### Optional scenarios (manual / later)

| Scenario | Notes |
|----------|--------|
| Agent / voice load | Expensive (Vertex); keep off soak default; separate probe |
| Invoice generation | Month-bound; trigger scheduler manually if needed |
| Platform-admin provision | Not resident traffic; keep out of soak |
| Progressive ramp | Future: `--ramp 10m` linear worker ramp |

---

## Before you start (checklist)

1. **Seed complete** on test-03 (~20 tenants, residents + facilities).  
2. **Env powered on** and **hold nightly disable** for the soak window:

   ```bash
   make env-enable ENV=test-03
   make env-hold ENV=test-03 DAYS=1 REASON="soak test"
   ```

3. **Warm + latency profile** (recommended for ~1s p95 target under soak):

   Cloud Run only scales past 1 instance when concurrent requests approach
   `containerConcurrency`. A light soak with concurrency=80 stays on **one**
   instance and p95 climbs to ~3s. For soak/perf days on **test only**:

   ```bash
   # Low latency profile (test-03): always-on CPU, early scale-out, min 2
   gcloud run services update sport-slot-api \
     --project=slot-sense-test-03 --region=asia-south1 \
     --min-instances=2 \
     --max-instances=10 \
     --concurrency=10 \
     --cpu=2 \
     --memory=1Gi \
     --no-cpu-throttling \
     --cpu-boost

   # After soak — cheaper idle (optional)
   gcloud run services update sport-slot-api \
     --project=slot-sense-test-03 --region=asia-south1 \
     --min-instances=0 \
     --concurrency=80 \
     --cpu=1 \
     --memory=512Mi \
     --cpu-throttling
   ```

   Verify:

   ```bash
   gcloud run services describe sport-slot-api \
     --project=slot-sense-test-03 --region=asia-south1 \
     --format='yaml(spec.template.metadata.annotations,spec.template.spec.containerConcurrency,spec.template.spec.containers[0].resources)'
   ```

4. **Auth ADC** for Firestore user sampling:

   ```bash
   gcloud auth application-default login
   gcloud config set project slot-sense-test-03
   ```

5. **Open monitoring** (keep visible the whole run):

   | Surface | What to watch |
   |---------|----------------|
   | **SlotSense Ops** dashboard (Cloud Monitoring) | 5xx ratio, p95 latency, instance count, uptime |
   | **Cloud Run → sport-slot-api → Metrics** | Request count, latency, container CPU/mem, instance count |
   | **Cloud Logging** | `severity` / `LOCK` / `503` spikes |
   | **Alert policies** (email/SMS) | error_rate, latency, uptime — confirm channels still receive |
   | **Redis / Memorystore** | CPU/memory if available; booking 503s if Redis unhealthy |

   Console deep links (project `slot-sense-test-03`, region `asia-south1`):

   ```text
   https://console.cloud.google.com/run/detail/asia-south1/sport-slot-api/metrics?project=slot-sense-test-03
   https://console.cloud.google.com/monitoring/dashboards?project=slot-sense-test-03
   https://console.cloud.google.com/logs/query?project=slot-sense-test-03
   ```

6. **Frontend deploy** with latest code if you will also click around during soak (optional).

---

## Run

```bash
cd backend

# Short validation (10–15 min) — rush immediately
uv run python ../scripts/soak_test.py \
  --project slot-sense-test-03 \
  --base-domain slotsense-test.chandraailabs.com \
  --duration 15m \
  --tenant-pct 15 \
  --users-per-tenant 8 \
  --workers 12 \
  --rush-now \
  --report ../soak-report.json

# Full morning-rush soak (start before 08:00 IST)
uv run python ../scripts/soak_test.py \
  --project slot-sense-test-03 \
  --base-domain slotsense-test.chandraailabs.com \
  --duration 3h \
  --tenant-pct 15 \
  --users-per-tenant 12 \
  --workers 16 \
  --rush-at 08:00 \
  --rush-n 60 \
  --report ../soak-report-morning.json
```

Makefile:

```bash
make soak-test                          # defaults: 30m, rush-now, test-03
make soak-test DURATION=2h RUSH=--rush-at\ 08:00
```

### Important flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--duration` | `30m` | Steady phase length (`30m` / `2h` / `3600s`) |
| `--tenant-pct` | `15` | % of seeded tenants participating |
| `--users-per-tenant` | `8` | Residents sampled + signed in per tenant |
| `--workers` | `12` | Concurrent steady-state workers |
| `--rush-now` | off | Immediate 08:00-style flash |
| `--rush-at 08:00` | off | Wait until 08:00 **Asia/Kolkata** then flash |
| `--rush-n` | `40` | Max contenders in flash |
| `--pace-ms` | `80` | Delay between ticks per worker (lower = hotter) |
| `--report` | `soak-report.json` | JSON summary path |

Password defaults to seed `ResidentPass143$`. Firebase API key defaults from
`infrastructure/firebase-web-configs/slot-sense-test-03.json` when project is test-03.

---

## What “good” looks like

| Signal | Healthy | Investigate |
|--------|---------|-------------|
| **Lock proof** | `lock_proof.ok ≥ 1`, fail ≈ 0 | Double 201 → lock/Redis regression |
| **Rush winners** | ~1 per tenant facility/slot | Multiple 201 same slot → FAIL closed broken |
| **p95 latency** | Stable; no multi-second climb all soak | Instance starvation, cold start, Firestore hot spots |
| **5xx rate** | Near 0; brief blips only | Redis AUTH, Cloud Run capacity, quota |
| **503 LOCK_UNAVAILABLE** | Rare | Redis down or VPC path |
| **Tenant coverage** | ≥ ~15% of 20 tenants in report | Sampling/auth failures |
| **Alerts** | May tick on aggressive rush — confirm recovery | Stuck firing after soak ends |

Report fields (excerpt):

```json
{
  "latency_ms": { "p50": 120, "p95": 480, "p99": 900 },
  "bookings_created": 400,
  "bookings_cancelled": 180,
  "active_tenant_count": 3,
  "rush": { "contenders": 40, "winners": 3 },
  "lock_proof": { "ok": 5, "fail_double_book": 0, "inconclusive": 2 },
  "contention": {
    "double_book_count": 0,
    "events": [
      {
        "result": "PASS",
        "slot_key": "orchid-park/fac-…/2026-08-07/09:00",
        "winners": [{ "email": "…@example.com", "booking_id": "fac-…_2026-08-07_09:00" }]
      }
    ],
    "double_books": []
  },
  "cloud_run": { "min_instances": 1, "max_instances": 1 }
}
```

**Reading contention:**

| `result` | Meaning |
|----------|---------|
| `PASS` | Exactly one `201` — winner email + `booking_id` + `slot_key` recorded |
| `DOUBLE_BOOK` | Two+ `201`s for the same facility/date/start — **bug** |
| `INCONCLUSIVE` | Zero `201`s (usually all `422 SLOT_NOT_BOOKABLE` because steady traffic took the slot first) — **not** a lock failure |

```bash
jq '.contention.double_books, .cloud_run, .lock_proof' soak-report.json
```

---

## During the soak (operator)

1. Leave the terminal log scrolling (progress every ~50 ops).  
2. Watch **instance count** scale up under rush, down after.  
3. Spot-check UI: tenant admin daily overview / facilities still usable.  
4. If chaos: lower `--workers` / raise `--pace-ms`; do **not** point at prod.  
5. If nightly job might fire: confirm **hold** still active (`make env-status ENV=test-03`).

---

## After the soak

```bash
# Inspect report
jq '.latency_ms, .lock_proof, .rush, .active_tenants' soak-report.json

# Optional: return Cloud Run to cheap idle
gcloud run services update sport-slot-api \
  --project=slot-sense-test-03 --region=asia-south1 \
  --min-instances=0

# Optional: sleep env (FinOps) when done for the day
make env-release-hold ENV=test-03
make env-disable ENV=test-03
```

Capture notes: p95, 5xx, lock_proof, any alert emails, dashboard screenshots → attach to release / SLO-LOAD-TEST backlog closeout.

---

## Safety

- Script **refuses** project ids without `test` unless `--allow-non-test`.  
- Does **not** delete tenants, facilities, or Auth users.  
- Creates real bookings on **test** data (seed residents) — expect Firestore growth; cancels reclaim many.  
- Never run against production customer traffic.

---

## Related

- ADR-0045 test strategy · ADR-0040/0041 observability  
- `scripts/concurrency_test.py` — single-slot unit stress  
- `tests/functional/test_concurrency.py` — S-FUNC lock proof  
- Backlog **SLO-LOAD-TEST** / **PERF-BASELINE**
