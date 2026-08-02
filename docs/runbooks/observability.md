# Observability & Alerting Runbook

- **Status:** Baseline shipped (PR-2, pending Coordinator apply);
  SLO definition + ops dashboard added (PR-3, pending Coordinator
  apply); cost guardrails added (PR-4, pending Coordinator apply)
- **Governing ADR:** [ADR-0040](../adr/0040-observability-and-alerting.md),
  [ADR-0041](../adr/0041-availability-slo-redis.md),
  [ADR-0042](../adr/0042-cost-guardrails.md)
- **Last updated:** 2026-07-21

## SLO definition (ADR-0041 D14)

**99% monthly availability, measured not modeled.** Availability holds
only when **both** of the following hold over the calendar month:

1. The edge uptime check
   (`probe.slotsense.chandraailabs.com/health`) success rate ≥ 99%.
2. The 5xx ratio stays under the ADR-0040 alert threshold (>5%/5min
   triggers the `error_rate` alert policy above).

Error budget: **~7.3 hours/month**. This is deliberately a doc-level
definition, reviewable from the "SlotSense Ops" dashboard (below) —
Monitoring SLO / error-budget burn-rate API resources are **not**
created yet. Burn-rate alerting without measured traffic distributions
is theater (same reasoning as ADR-0040's provisional thresholds); that
upgrade is explicitly gated behind backlog `SLO-LOAD-TEST`.

## Cloud Run headroom and probes (ADR-0041 D15)

`terraform/cloud_run.tf`, `google_cloud_run_v2_service.sport_slot_api`:

- `maxScale`: 2 → 10 — a cap, not a floor; `minScale` stays 0 (cold
  starts accepted at dev-stage traffic within a 99% SLO; an always-on
  instance is pure ceiling burn for a latency concern the SLO doesn't
  require solving).
- Startup probe: TCP → **HTTP GET `/health`**.
- **Liveness probe added: HTTP GET `/health`.** `/health`
  (`backend/src/sport_slot/health.py:14`) is pure liveness by design —
  a dependency-checking endpoint (e.g. `/readyz`) would wrongly
  restart the container on a transient Redis/Firestore blip.
- This apply mints the first Terraform-driven Cloud Run revision since
  PR-1b adoption; live image/env are untouched (D7 `ignore_changes`
  model). See the PR-3 PR body for the Coordinator post-apply
  watchlist.

## "SlotSense Ops" dashboard (ADR-0041 D17)

`terraform/dashboard.tf`, `google_monitoring_dashboard.slotsense_ops`
— one bookmarkable URL instead of Metrics Explorer archaeology: voice
turns/day, agent text turns/day, 5xx error ratio, p95 latency, edge
uptime (check passed), Cloud Run instance count. This is an ops
convenience panel, not the deferred SLO-burn-rate dashboard (D14).

## Cost alerts (ADR-0042 D18)

`terraform/cost.tf`, `google_billing_budget.slotsense_dev_ceiling` — one
budget on the billing account, filtered to `sport-slot-dev` only, amount
₹5,000/month (ADR-0005 dev ceiling). Five graduated thresholds, all
routed to the **same two channels as outage alerts** (Email + SMS,
`local.observability_channels`):

| Threshold | Basis | Meaning |
|---|---|---|
| 50% | Current spend | Early signal — normal-month awareness |
| 80% | Current spend | Attention — on pace to breach |
| 100% | Current spend | Ceiling reached |
| 120% | Current spend | Breach escalation |
| 100% | Forecasted spend | Google's projection says the month will breach — earliest actionable runaway warning |

**Alert-only by design (D18):** no automated response (billing disable,
service caps) is wired to any threshold — billing-disable would destroy
serving ability as collateral damage, and every automated actuator is a
new outage mode. The human is the actuator; a threshold firing means
**go look**, not "something already happened automatically."

**What to check first when a cost alert fires:** the "SlotSense Ops"
dashboard's turn-volume widgets — **Voice turns/day** and **Agent text
turns/day** (`terraform/dashboard.tf`, ADR-0041 D17). Voice is the
highest per-unit-cost surface (≈₹1/turn); a spend spike with no
corresponding turn-count spike points elsewhere (scaling incident, a
forgotten drill environment, a non-voice service) rather than organic
usage growth.

Billing-admin default recipients stay enabled as backup
(`disable_default_iam_recipients = false`) — the two ADR-0040 channels
are the primary path, not the only one.

## What exists

All Terraform-managed in `terraform/observability.tf` (ADR-0040). Every
resource is a **create** — nothing pre-existing to reconcile against.

| Alert | Condition | Window | Notifies |
|---|---|---|---|
| 5xx error rate | > 5% of requests | 5 min | Email + SMS |
| p95 latency | > 2500ms | 15 min | Email + SMS |
| Uptime check failure | Either check (edge or service path) failing from ≥2 regions | check-native | Email + SMS |
| Firestore backup failure | Log-based metric `firestore_backup_failures` > 0 | per-event | Email + SMS |

Plus: Error Reporting enabled (`clouderrorreporting.googleapis.com`),
and two counting-only log-based metrics (`voice_turns`,
`agent_text_turns`) with no alert attached — they feed PR-4's
billing-budget thresholds, not paging.

**Uptime checks (two, deliberately redundant):**
- **Edge path:** `https://probe.slotsense.chandraailabs.com/health` —
  a reserved, tenant-independent host (wildcard DNS + wildcard cert
  already cover it), not a real tenant subdomain like `rvrg`: an
  unauthenticated `/health` probe never exercises tenant resolution
  anyway, so tenant-routing verification belongs to `SMOKE-E2E`, not
  an uptime check. Still exercises DNS, cert, Cloud Armor, LB, and
  backend together.
- **Service path:** the Cloud Run service URL's `/health` directly —
  isolates app health from edge health. One red / one green localizes
  the fault layer immediately.

Both check `GET /health` (`backend/src/sport_slot/health.py:14`) —
pure liveness, no dependency calls — not `/readyz`, which pings
Firestore and would conflate app health with a Firestore blip.

**Thresholds are provisional** (measured-gates principle): set loose
now, tightened once `SLO-LOAD-TEST` (PR-3 follow-on) produces real
traffic distributions. See backlog `ALERT-THRESHOLD-TUNE`.

**Documented residual:** the backup alert detects *failed* backup
operations; it does not detect a schedule that silently never runs.
Absence-detection is `BACKUP-ABSENCE-ALERT` on the backlog, not this PR.
Separately, the `firestore_backup_failures` log filter itself is
defensive/provisional — no real backup failure has occurred yet to
observe the actual Cloud Audit Log shape. **Validate this filter at
the DR drill or the first real failure**, whichever comes first.

## Where alerts go

Two notification channels, both wired to all four alert policies:

- **Email** — `admin@chandraailabs.com`, Terraform-managed.
- **SMS** — Coordinator's number. **Console-owned operator config,
  Terraform-referenced read-only** (`data
  "google_monitoring_notification_channel"` on display name
  `"Coordinator SMS"` — mirrors ADR-0038's secret shells-vs-values
  pattern). The number never appears in the repo, in Terraform state,
  or in tfvars. Creating the channel is a **PRE-apply step**, below.

## Pre-apply step (Coordinator) — create the SMS channel

Before running `terraform plan`/`apply` on this PR for the first time:

1. In the console: Monitoring → Alerting → Notification Channels →
   Add SMS. Set the display name to **exactly** `Coordinator SMS` —
   this is the contract `terraform/observability.tf`'s data source
   depends on; a mismatch fails plan loudly (by design — that's the
   guardrail, not a bug).
2. Enter the Coordinator's number and complete the one-time
   verification code sent to it. An unverified channel still exists
   (satisfying the data source) but won't actually deliver — verify it
   now, not after apply.

To change the number later: edit it in the console. No Terraform
apply needed, and none will revert it — unlike a hardcoded value or a
tfvars-supplied one, there's nothing in this repo to drift back to.

## Post-apply steps (Coordinator)

1. Confirm both uptime checks go green within ~5 minutes of apply.
2. Send a test notification from one alert policy (console "Test
   Notification" button) — confirm **both** email and SMS actually
   arrive, not just that the channel shows as configured.
3. Check Metrics Explorer: trigger one live voice turn in the app and
   confirm `voice_turns` increments.
4. `terraform plan` from `main` post-apply → expect **No changes**.

## Known gap, tracked

`agent_text_turns` and `voice_turns` are built on Cloud Run **platform**
request logs (`run.googleapis.com/requests`), not application logs —
verified against a real `/agent/query` log entry. The application's
own structured logging doesn't give an unconditional per-turn event
for text-agent turns today (`voice.py` logs `voice_request_received`
unconditionally; `agent.py`'s `/query` router and
`orchestrator.run_agent` do not have an equivalent — see backlog
`AGENT-TURN-EVENT` for the follow-up that would add one with
tenant/latency/model dimensions for PR-4's per-tenant cost
attribution). Platform request logs are the interim source and remain
the volume-counter of record until then.
