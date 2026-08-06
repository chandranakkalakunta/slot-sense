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
| 2 | **Realistic population (default)** | **All tenants** + ~**10–15% of users per tenant** (capped) so quota is spread |
| 3 | 08:00 morning stress | `--rush-at 08:00` (Asia/Kolkata) or `--rush-now` for immediate flash |
| 4 | Watch monitoring live | Ops dashboard + Cloud Run metrics open during run (below) |
| 5 | Lock correctness under load | Periodic **N-parallel same-slot** waves (expect 1 winner) |
| 6 | Multi-hour sustainability | Cancel-aware mix recycles slots + daily quota (avoids early 409 wall) |

### Realistic vs legacy

| Mode | Tenants | Users | Traffic | Use when |
|------|---------|-------|---------|----------|
| **`realistic` (default)** | All seeded | ~`user_pct` (12%) of each tenant, capped (`max-users-per-tenant` 40, `max-total-actors` 500) | Prefer **cancel when holding bookings**, book when free | Long soaks, production-like occupancy |
| **`legacy`** | `tenant-pct` (e.g. 15% → 3 of 20) | Fixed `users-per-tenant` (e.g. 8) | Fixed 25% book / 15% cancel | Quick narrow debug |

**Why realistic exists:** With 3 tenants × 8 users, daily `max_slots_per_user_per_sport_per_day` (seed default **2**) is exhausted quickly → `created` freezes and the soak becomes read-only + failed books. Spreading load across **all tenants** and **many more residents**, plus **cancel recycling**, keeps successful bookings possible for 2h+.

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

1. **Re-authenticate ADC** (required every day / after laptop sleep — soak samples Firestore):

   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project slot-sense-test-03
   ```

   The harness runs an **ADC preflight** first; if you see  
   `Reauthentication is needed` / `invalid_rapt` / `RetryError: Timeout`,  
   run the commands above and restart soak. Non-interactive reauth is not possible.

2. **Seed complete** on test-03 (~20 tenants, residents + facilities).  
3. **Env powered on** and **hold nightly disable** for the soak window:

   ```bash
   make env-enable ENV=test-03
   make env-hold ENV=test-03 DAYS=1 REASON="soak test"
   ```

4. **Warm + latency profile** (recommended for ~1s p95 target under soak):

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

### Harness auto-steps (realistic soak)

| Step | Default |
|------|---------|
| ADC preflight | Fail fast with reauth instructions |
| Fresh Firebase sign-in for all actors | At start |
| Token refresh | Every **45 min** (and proactive mid-interval wave) |
| Temporary quota | `max_slots_per_user_per_sport_per_day` → **10** on active tenants (`--soak-quota-slots 0` to skip) |
| Latency percentiles | **Exclude HTTP 401** (expired-token noise) |

---

## Run

```bash
cd backend

# Short validation — realistic mode (default)
uv run python ../scripts/soak_test.py \
  --duration 15m --rush-now --report ../soak-report.json

# Multi-hour realistic soak (all tenants, ~12% users capped)
uv run python ../scripts/soak_test.py \
  --duration 2h --rush-now \
  --user-pct 12 --max-users-per-tenant 40 --max-total-actors 500 \
  --workers 24 \
  --report ../soak-report-2h.json

# Real morning-rush (start before 08:00 IST)
uv run python ../scripts/soak_test.py \
  --duration 3h --rush-at 08:00 --rush-n 80 \
  --report ../soak-report-morning.json
```

Makefile:

```bash
make soak-test                              # realistic, 30m, rush-now
make soak-test DURATION=2h
make soak-test DURATION=2h USER_PCT=15 MAX_ACTORS=600 WORKERS=32
make soak-test-legacy DURATION=15m          # old 15% tenants × 8 users
```

### Important flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--mode` | `realistic` | `realistic` \| `legacy` |
| `--duration` | `30m` | Steady phase (`30m` / `2h` / `3600s`) |
| `--user-pct` | `12` | **[realistic]** % of each tenant’s seeded users (aim **10–15**) |
| `--max-users-per-tenant` | `40` | Cap after user-pct (auth cost control) |
| `--max-total-actors` | `500` | Global actor cap after per-tenant plan |
| `--tenant-pct` | `15` | **[legacy]** % of tenants |
| `--users-per-tenant` | `8` | **[legacy]** fixed residents per tenant |
| `--workers` | `24` | Concurrent steady-state workers |
| `--rush-now` | off | Immediate flash |
| `--rush-at 08:00` | off | Wait until 08:00 **Asia/Kolkata** |
| `--rush-n` | `80` | Max contenders in flash |
| `--pace-ms` | `80` | Delay between ticks per worker |
| `--report` | `soak-report.json` | JSON summary path |
| `--token-refresh-minutes` | `45` | Re-mint Firebase ID tokens before ~1h expiry |
| `--soak-quota-slots` | `10` | Temp raise daily booking quota for soak tenants (0 = leave policy) |

**Auth cost:** realistic mode may sign in hundreds of users (capped). First minutes are ADC check + auth + optional quota bump + facility warm-up.

**Quota note:** soak writes `policies.max_slots_per_user_per_sport_per_day` on each active tenant (default 10). Re-seed or PATCH policies later if you want seed default (2) restored.

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
| `DOUBLE_BOOK` | Two+ `201`s for the same facility/date/start **before any cancel** — **product bug** |
| `INCONCLUSIVE` | Zero `201`s (usually all `422 SLOT_NOT_BOOKABLE` because steady traffic took the slot first) — **not** a lock failure |

```bash
jq '.contention.double_books, .cloud_run, .lock_proof' soak-report.json
```

### Investigation note (2026-08-05 soak)

One `DOUBLE_BOOK` was recorded on `azure-bay` / facility `0c1738f33c95` /
`2026-08-07 18:00` with two different residents both receiving **201** and the
**same** `booking_id`.

**Root cause (harness, not concurrent confirmed occupancy):** lock-proof used to
**cancel the winner inside the parallel wave**. Timeline:

1. Resident A acquires Redis lock → creates confirmed booking → **201** → **cancels**
2. Resident B then acquires lock → sees **cancelled** doc → allowed re-book
   (`txn.set` on cancelled — intentional product behavior) → **201**
3. Harness counted two 201s as DOUBLE_BOOK

Product defenses (Redis `SET NX`, deterministic id, Firestore “confirmed →
AlreadyBooked”) remain correct for **two simultaneous confirmed** bookings.
Re-book after cancel is allowed by design.

**Fix:** cancel only **after** the whole contention wave is scored (see
`scripts/soak_test.py`). Re-run soak; any remaining DOUBLE_BOOK is real.

### Latency guidance

| Metric | Typical under soak (scaled) | Acceptable? |
|--------|----------------------------|-------------|
| p50 | ~0.5–0.8s | Yes for multi-step booking |
| p95 | ~1–2s with 2–5 instances | **Target ≤1s** for flash UX; ≤2s OK for test soak |
| p99 / max | 3–12s | Tail from cold start of new instances, queueing, Firestore |

**Why max ~11s appeared:** Cloud Run scaled 2→5; new instances pay cold-start
+ first-request cost while other requests queue. Not the same as steady p50.
Reduce tail with higher `min-instances` during soak (e.g. 4–5) or accept rare
cold tails when scaling out.

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
