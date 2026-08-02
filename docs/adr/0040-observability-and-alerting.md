# ADR-0040: Observability & Alerting Baseline

- **Status:** Proposed (awaiting Coordinator approval)
- **Date:** 2026-07-17
- **Phase:** 17 — Production Readiness / PR-2
- **Related:** ADR-0038 (backup-failure alert deferred here), ADR-0005
  (cost ceilings), baseline audit 2026-07-13 (finding #2), docs/backlog.md
  (PR-2-OBSERVABILITY, BACKUP-ALERT)

## Context

The 2026-07-13 baseline audit found **zero alerting and zero uptime
checks**: an outage, error storm, latency collapse, or failed backup
would go undetected indefinitely. The 99% availability SLO (fixed
premise) is unmeasurable without instrumentation. ADR-0038 explicitly
deferred backup-failure alerting to this sub-phase. Voice added a
≈₹1/turn cost surface with no visibility into turn volume.

## Decision

A minimal, Terraform-managed observability baseline. Everything below
is code (no console-created resources); this is the first operational
use of `sa-monitoring`'s purpose.

### D9 — Notification channels

- **Email** to admin@chandraailabs.com — a
  `google_monitoring_notification_channel` resource, Terraform-managed
  like everything else in this ADR.
- **Native SMS** to the Coordinator's number — **console-owned
  operator config, Terraform-referenced read-only** via a
  `data "google_monitoring_notification_channel"` lookup on its
  display name, not a managed resource. This mirrors ADR-0038's
  secret shells-vs-values pattern: contact information (like a secret
  value) is operator config that Terraform reads, not something it
  creates or stores. The number never appears in the repo, in state,
  or in tfvars. Creating the channel (console) and completing its
  one-time verification are documented PRE-apply steps — the data
  source fails plan loudly if the channel doesn't exist yet, which is
  the intended guardrail, not a bug to work around.
- Optional free third leg: Google Cloud mobile-app push (console-side,
  not TF; Coordinator discretion).
- **Rejected: WhatsApp** — not a native channel; requires a third-party
  webhook integration (Twilio/Meta), a new secret (ADR-0038 Layer 2
  inventory obligation), and per-message cost, duplicating what native
  SMS provides. Revisit only if SMS delivery proves unreliable.
- **Rejected: hardcoded number in `.tf`** — a phone number is PII-
  adjacent contact info, not infrastructure shape; committing it
  couples every future number change to a Terraform apply and puts it
  in git history permanently.
- **Rejected: number via `terraform.tfvars`** — an earlier revision of
  this ADR took this approach (gitignored, `sensitive` variable). Still
  rejected on reflection: it still couples a contact-info change to
  running `apply`, and gitignored-but-locally-required state is an
  easy-to-miss rebuild step (see DR runbook history). Console-owned
  config needs no apply at all to update.
- **Rejected: dummy placeholder number, console-edited after apply** —
  the earliest revision's approach. Rejected: the next `terraform
  apply` reverts the console edit back to the placeholder — a drift
  trap that silently breaks SMS delivery until someone notices.

### D10 — Uptime checks (two, deliberately redundant paths)

1. **Edge path:** HTTPS check against
   `https://probe.slotsense.chandraailabs.com/<health-route>` — a
   reserved, tenant-independent host (not a real tenant subdomain like
   `rvrg`), by design: an unauthenticated `/health` probe never
   exercises tenant resolution anyway, so probing a real tenant host
   buys nothing; tenant-routing verification is SMOKE-E2E's scope, not
   an uptime check's job. Still exercises DNS, certificate, Cloud
   Armor, LB, and backend together (the real resident path, minus
   tenant routing).
2. **Service path:** HTTPS check against the Cloud Run service URL's
   health route directly — isolates app health from edge health.
   One red / one green localizes the fault layer immediately.

The health route is verified from application code during
implementation, not assumed.

### D11 — Alert policies (initial thresholds are provisional)

| Signal | Condition | Window |
|---|---|---|
| Server error rate | 5xx > 5% of requests | 5 min |
| Latency | p95 > 2.5s | 15 min |
| Availability | either uptime check failing from ≥2 regions | check-native |
| Backup failure | log-based metric on failed Firestore backup operations > 0 | per-event |

Plus **Error Reporting enabled** (API + implicit ingestion from
structured logs; the EventRenamer fix from PR #134 already makes app
errors parseable).

Thresholds follow the measured-gates principle: set loose now,
tightened when SLO-LOAD-TEST (PR-3 follow-on) produces real
distributions. **Documented residual:** the backup alert detects
*failed* backup operations; it does not detect a schedule that
silently never runs. Absence-detection (a "no successful backup in
36h" condition) is a named refinement, logged on the backlog, not
in this PR.

### D12 — Voice/agent cost counters

Log-based counter metrics on `/agent/voice` and `/agent/query`
requests, giving turn-volume time series. Purpose: (a) anomaly
visibility on the ≈₹1/turn voice surface immediately; (b) measured
input for PR-4's billing-budget thresholds instead of guessed ones.
Counting only — no enforcement (rate limiting is VOICE-HARDEN-02,
budget action is PR-4).

### D13 — Delivery form

All of the above as Terraform resources in
`terraform/observability.tf`, plus `google_project_service` for any
required APIs not yet enabled (Error Reporting expected off per the
audit). All resources are **creates** — no imports; §2.7's
merge-before-apply ordering still applies.

## Alternatives considered

1. Console-created alerts — rejected: regresses ADR-0038's
   "apply is the rebuild path" consequence the week after shipping it.
2. WhatsApp channel — rejected (D9 rationale above).
3. Full dashboards/SLO burn-rate alerting — rejected for now:
   burn-rate math without measured traffic distributions is theater;
   revisit with PR-3/SLO-LOAD-TEST data.

## Cost impact (§4.5)

Uptime checks, alert policies, notification channels, and log-based
metrics at this volume: free tier / noise. SMS notifications are free
via Cloud Monitoring's native channel. No ceiling pressure.

## Consequences

- The 99% SLO becomes measurable; outages and failed backups page a
  human within minutes instead of never.
- Voice cost exposure becomes a visible time series feeding PR-4.
- New backlog obligations: BACKUP-ABSENCE-ALERT (refinement),
  threshold-tightening after SLO-LOAD-TEST.
- BACKUP-ALERT and PR-2-OBSERVABILITY close on merge+apply of this
  sub-phase.
