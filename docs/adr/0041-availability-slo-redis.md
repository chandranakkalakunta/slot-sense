# ADR-0041: Availability, SLO Formalization & the Redis Decision

- **Status:** Accepted
- **Date:** 2026-07-17
- **Phase:** 17 — Production Readiness / PR-3
- **Related:** ADR-0040 (observability baseline), ADR-0005 (cost
  ceilings), baseline audit 2026-07-13 (findings #3, #8),
  docs/backlog.md (PR-3-AVAILABILITY, SLO-LOAD-TEST)

## Context

The availability SLO (99%, single-region — fixed premise) has never
been formalized or measured. The audit found thin Cloud Run headroom
(maxScale=2, shallow TCP startup probe, no liveness probe) and named
Redis a hard single point of failure: BASIC tier, one node, no
persistence, with booking-slot locking and password-reset both failing
closed (503) on any Redis error. PR-2 built the measurement
infrastructure this ADR now uses.

## Decision

### D14 — SLO: 99% monthly availability, measured not modeled

Availability is defined as BOTH holding: (a) edge uptime check
(probe.slotsense.chandraailabs.com/health) success rate ≥ 99% over the
calendar month; (b) 5xx ratio remaining under the ADR-0040 alert
threshold. Error budget: ~7.3 hours/month. Deliberately NOT creating
Monitoring SLO / error-budget burn-rate resources yet — burn-rate
alerting without measured traffic distributions is theater (ADR-0040's
own reasoning). That upgrade is explicitly gated behind SLO-LOAD-TEST.

### D15 — Cloud Run headroom and probes

- `maxScale: 2 → 10`. A cap, not a floor: zero cost until real traffic
  scales instances. minScale stays 0 — cold starts are acceptable
  inside a 99% SLO at dev-stage traffic, and an always-on instance is
  pure ceiling burn.
- Startup probe: TCP → **HTTP GET /health** (initial_delay/period
  tuned modestly; the endpoint is pure liveness, no dependency calls).
- **Liveness probe added: HTTP GET /health.** Pure-liveness semantics
  is exactly what a liveness probe must have (a dependency-checking
  endpoint would wrongly restart the container on Redis/Firestore
  blips).
- Operational note: these are template changes — the apply mints the
  first Terraform-driven revision since adoption. The D7/ignore_changes
  model preserves live image+env; the apply is watched accordingly.

### D16 — Redis: BASIC tier ACCEPTED as documented residual

STANDARD_HA is rejected at this stage: it roughly doubles Redis cost
against the ₹5K ceiling to protect an SLO that already tolerates
~7.3h/month, for a dev-stage system with no paying tenants. The
fail-closed 503 in booking-slot locking is AFFIRMED as correct design,
not defect: failing open would permit double-booking — integrity over
availability for reservations. Password-reset fail-closed is an
accepted annoyance at this scale.

**Revisit triggers (any one reopens this decision):**
- First paying tenant / Phase 18 production launch gate
- A measured Redis-attributed SLO breach or repeated Redis incidents
- Memorystore maintenance windows observed impacting bookings

### D17 — "SlotSense Ops" dashboard

One Terraform-managed Monitoring dashboard: voice turns, agent text
turns, 5xx ratio, p95 latency, edge uptime status, Redis/Run instance
basics. Purpose: kill Metrics-Explorer archaeology; one bookmarkable
URL. This is an ops panel, not the deferred SLO-burn-rate dashboard.

## Alternatives considered

1. Monitoring SLO API + burn-rate alerts now — rejected until
   SLO-LOAD-TEST provides distributions (D14).
2. minScale=1 to eliminate cold starts — rejected: always-on cost
   for a latency concern the SLO doesn't require solving.
3. STANDARD_HA Redis — rejected with triggers (D16).
4. Dependency-checking health endpoint for liveness — rejected:
   restarts are the wrong response to dependency blips.

## Cost impact (§4.5)

maxScale raise: ₹0 until traffic demands it. Probes: free. Dashboard:
free. Redis unchanged. Net new recurring cost: zero.

## Consequences

- The SLO becomes a measured monthly number, reviewable from the
  dashboard.
- Capacity ceiling 5× with no idle cost; container restarts become
  deliberate (liveness) rather than never.
- The Redis SPOF is now a *decision with triggers* instead of an
  unexamined risk — audit finding #3 closes as "accepted, documented,
  monitored."
- SLO-LOAD-TEST remains the named follow-on that upgrades D14 and
  re-tests D15 settings.
