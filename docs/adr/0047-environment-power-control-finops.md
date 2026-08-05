# ADR-0047: Environment Power Control (FinOps Sleep / Wake)

- **Status:** Accepted
- **Date:** 2026-08-05
- **Related:** ADR-0005 (cost baseline), ADR-0009 (Memorystore Redis),
  ADR-0041 (Redis residual / Cloud Run scale), ADR-0042 (cost
  guardrails — alert-only budgets), ADR-0045 (multi-env test strategy),
  ADR-0046 (per-env base domains)

## Context

SlotSense runs multiple GCP projects (today: `sport-slot-dev`,
`slot-sense-dev-03`, `slot-sense-test-01`, `slot-sense-test-03`). Fixed
cost is dominated by **Memorystore Redis Basic 1 GB**
(~₹2,500–3,000/month per project — ADR-0005 / ADR-0009). Cloud Run at
`min_instances > 0` adds further idle burn. Load balancers, static
IPs, Artifact Registry, and storage add smaller residual costs.

Environments are often idle overnight and on non-work stretches.
Leaving Redis (and warm Cloud Run) running 24×7 wastes budget before
real customers exist. Operators need a **FinOps power control**:

1. **Manual disable** of a complete environment so billable runtime
   cost drops to residual (near-zero for Redis/compute).
2. **Manual enable** when work or testing is needed.
3. **Automatic disable every night at 23:00 Asia/Kolkata** if the
   environment is up — no charge for the overnight window.
4. **Hold / override** so soak tests, concurrency runs, or other
   multi-day work are **not** killed by the nightly job.
5. **All current environments** participate in nightly disable.
   Once real customers run on production, **prod nightly disable is
   turned off** by config; manual power control may remain.

This ADR does **not** replace ADR-0042 budgets (alert-only). It adds
an **operator- and schedule-driven actuator** for sleep/wake, which
ADR-0042 deliberately left to humans rather than billing-disable.

## Options considered

### Option A — Full project / Terraform destroy each night

Destroy most Terraform-managed resources; recreate on enable.

**Strengths:** Closest to absolute zero cost.  
**Weaknesses:** Slow (hours), high risk to DNS/certs/LB, breaks
same-day resume, fights CI/state. Unsuitable for daily cycle.

### Option B — Scale Cloud Run only (leave Redis)

Set `min_instances=0`; leave Memorystore running.

**Strengths:** Fast, simple, no Redis host/auth churn.  
**Weaknesses:** Misses the majority of fixed cost (Redis). Does not
meet the “near-zero when disabled” intent.

### Option C — Operational power control (chosen)

`gcloud`-driven sleep/wake **without** tearing down data or edge:

| On disable | Action |
|------------|--------|
| Memorystore Redis | **Delete** (cannot stop; only delete) |
| Cloud Run | Force **min instances = 0** |
| Cloud Scheduler jobs | **Pause** |
| Uptime checks | **Pause** (avoid false pages / wake traffic) |
| LB, static IP, certs, Firestore, Auth, AR, secret *metadata* | **Keep** |

On enable: recreate Redis (same shape), refresh `redis-auth` secret,
patch Cloud Run `SPORTSLOT_REDIS_*`, restore min instances from
profile, resume scheduler + uptime, smoke `/health`.

Hold marker (per project, e.g. GCS) skips nightly disable until a
timestamp. Nightly runner is automation (initially GitHub Actions
cron at 23:00 IST); optional later: per-project Cloud Scheduler.

**Strengths:** Removes Redis + compute burn; preserves data and DNS;
enable is minutes not hours; hold supports soak.  
**Weaknesses:** Residual LB/IP/storage cost remains; enable waits on
Redis READY (~10–20 min); ephemeral lock/cache state lost on sleep
(acceptable — booking SoR is Firestore); Terraform may show Redis
drift if apply runs while disabled.

### Option D — Disable the billing account / hard service caps

**Rejected** for the same reasons as ADR-0042 D18: nuclear collateral
and new outage modes. Budget alerts stay alert-only.

## Decision

**Adopt Option C — Environment Power Control (FinOps sleep/wake).**

### D1 — Scope of “disabled”

- **Near-zero runtime cost**, not absolute zero.
- Residual while disabled: global LB / static IP class costs, object
  storage, Artifact Registry storage, idle Firestore/Auth metadata.
- **Not** deleted on disable: tenant data, users, frontend assets,
  certificates, DNS targets, images.

### D2 — Manual control

Idempotent operator CLI (name illustrative: `scripts/env-power.sh`)
with explicit `--env` (same registry as `tf.sh`: `dev`, `dev-03`,
`test-01`, `test-03`, …):

- `status` / `disable` / `enable` / `hold` / `release-hold` / `list`
- Interactive confirmation on disable unless non-interactive (`--yes`
  for automation only)

### D3 — Nightly auto-disable

- **When:** 23:00 **Asia/Kolkata** daily.
- **What:** For each registered env with `nightly_disable: true`, if
  power state is ENABLED (or equivalent “up”) and **no active hold**,
  run the same disable sequence as manual.
- **Morning auto-enable:** **No.** Operator enables when needed
  (requirement: user controls wake).
- **Prod with real customers:** set `nightly_disable: false` for that
  env in the power-control registry; manual disable remains available
  for break-glass only if ever needed.

### D4 — Hold (soak / multi-day testing)

- Operator sets a hold with reason + expiry (`--until` or `--days`).
- Nightly job **must not** disable an env while `now < hold.until`.
- Hold is visible in `status`. Explicit `release-hold` clears early.
- Optional global kill-switch (e.g. CI variable) may skip the entire
  nightly workflow for emergencies.

### D5 — Implementation style

- **Operational scripts + thin config**, not nightly `terraform
  apply` / destroy cycles.
- Terraform remains source of truth for **desired powered-on shape**
  (Redis size/tier, Cloud Run max, LB). Power control is an
  operational overlay.
- Prefer a committed registry (e.g. `infrastructure/env-power.yaml`)
  listing project IDs, `nightly_disable`, and default
  `on_min_instances` restored on enable.
- Document residual cost, enable ETA, and “do not TF-apply while
  disabled without expecting Redis recreate” in a runbook after
  implementation.

### D6 — Safety

- Never disable the billing account.
- Never delete Firestore data, Auth users, or LB/certs in power scripts.
- Fail closed on ambiguous env selection (no default project).
- Nightly automation uses least-privilege identity (WIF + dedicated
  or existing CI SA with redis/run/scheduler/monitoring/secret/
  storage object rights as needed).

## Rationale

- Redis is the cost center; any plan that leaves it running fails the
  budget goal (Option B).
- Full destroy (Option A) is the right tool for **retiring** an env,
  not for overnight sleep.
- ADR-0042 keeps budgets alert-only; this ADR gives the human (and a
  scheduled stand-in for the human at 23:00) a **safe actuator**.
- Hold is mandatory for honest soak/concurrency testing without
  fighting the nightly job.
- Keeping LB/DNS avoids multi-hour cert/DNS thrash and matches
  ADR-0046 multi-env edge layout.

## Consequences

### Positive

- Material reduction in multi-env fixed cost (especially Redis × N
  projects).
- Clear operator UX: enable when working, disable or let night job
  sleep the rest.
- Soak-safe via hold.
- Prod can keep 24×7 later without redesign — flip one config flag.

### Negative / residual

- Enable is not instant (Redis provision latency).
- Residual networking/storage cost while “disabled”.
- Redis AUTH/host change on every wake → must refresh secret + Cloud
  Run env (same pattern as `setup_redis_infra.sh` / deploy).
- Possible Terraform drift if apply runs mid-sleep.

### Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Nightly kills soak | Hold with expiry + status visibility |
| Wrong env disabled | Explicit `--env`; confirm unless `--yes` |
| Enable half-done | Idempotent enable; status shows redis/run/hold |
| Alert noise while off | Pause uptime checks on disable |
| Prod auto-off after customers | `nightly_disable: false` before go-live |

## Out of scope (this ADR)

- Morning auto-wake schedules.
- Tearing down LB/DNS nightly.
- Per-tenant “power” (this is **environment / GCP project** level).
- Changing ADR-0005 budget ceilings or ADR-0042 threshold math.

## Implementation

Delivered with this decision’s implementation PR:

1. `scripts/env-power.sh` + Makefile targets (`env-enable`, `env-disable`, …)
2. `infrastructure/env-power.json` registry
3. Hold/state in `gs://<project>-env-power/` (bucket via Terraform)
4. `.github/workflows/env-nightly-disable.yml` (23:00 Asia/Kolkata)
5. `docs/runbooks/env-power.md`
6. `terraform/env_power.tf` — state bucket + CI WIF roles for nightly

## Cost impact

- Tooling (scripts, GHA, small GCS bucket): negligible.
- **Savings:** roughly one Redis Basic instance fee per disabled
  project-month of sleep (plus any min-instance hours avoided).
- **Residual while disabled:** LB/IP + storage class costs remain.
