# ADR-0042: Cost Guardrails — Billing Budget & Thresholds

- **Status:** Accepted
- **Date:** 2026-07-20
- **Phase:** 17 — Production Readiness / PR-4
- **Related:** ADR-0005 (cost ceilings: ₹5K/mo dev, ₹2K/tenant/mo
  prod), ADR-0040 (channels + turn metrics), baseline audit
  2026-07-13 (finding #5: no cost guardrail; Billing Budget API never
  enabled), docs/backlog.md (PR-4-COST)

## Context

The audit found zero cost guardrails: no budget exists, the Billing
Budget API has never been enabled, and the ₹5K/mo dev ceiling from
ADR-0005 is enforced by nothing but attention. Voice added a
≈₹1/turn surface; PR-2 made turn volume a visible metric but nothing
watches aggregate spend. A runaway (voice abuse, scaling incident,
forgotten drill environment) would surface only on the invoice.

## Decision

### D18 — One Terraform-managed budget, alert-only

A `google_billing_budget` on the billing account, scoped to
sport-slot-dev, amount = the ADR-0005 dev ceiling (₹5K/month,
in the billing account's currency as verified at implementation),
with threshold rules at:

- **50%** (actual) — early signal, normal-month awareness
- **80%** (actual) — attention: on pace to breach
- **100%** (actual) — ceiling reached
- **120%** (actual) — breach escalation
- **100% (forecasted)** — Google's projection says the month will
  breach: the earliest actionable warning of a runaway

Notifications route to the EXISTING ADR-0040 channels (Admin Email +
Coordinator SMS) via the budget's monitoring-notification-channels
binding — same pager for cost as for outages. Billing-admin default
emails remain as backup.

**Alert-only is a decision, not an omission:** automated responses
(disabling billing, capping services) are rejected — billing-disable
destroys the project's serving ability as collateral, and every
automated actuator is a new outage mode. The ₹5K scale does not
justify that risk; the human is the actuator.

**Amendment 2026-07-21:** The Budget API rejects
`monitoring_notification_channels` combined with default IAM
recipients, and rejected the SMS channel specifically (opaque 400 on
both create and update; isolated by removing the notification block,
which let the base budget + thresholds apply cleanly). Final wiring:
**Admin Email channel only**, codified in Terraform with
`disable_default_iam_recipients = true`. SMS is intentionally
omitted — cost alerts are slower-urgency than outage alerts and the
forecasted-breach threshold gives days of warning; the outage path
(PR-2) retains SMS. Supersedes the original "backup emails stay" note
(not achievable alongside a monitoring channel).

### D19 — Scope and plumbing

- `billingbudgets.googleapis.com` enabled via Terraform
  (`google_project_service`, disable_on_destroy=false) — first-ever
  enablement per the audit.
- Budget scoped by project filter to sport-slot-dev only, so the
  drill/TEST project (slot-sense-test, when it exists) and any other
  project on the billing account do not muddy the signal. A TEST
  budget is Phase 18's concern.
- credit_types_treatment: include credits as spend-reducing (default)
  — free-tier credits offsetting spend is the true cash picture.

## Alternatives considered

1. Automated billing disable at 120% — rejected (D18 rationale).
2. Pub/Sub budget notifications + Cloud Function responder — rejected:
   infrastructure for automation we just declined; revisit only if a
   real runaway proves the human path too slow.
3. Per-service budgets (voice vs core) — rejected for now: one
   project-level number matches ADR-0005's ceiling framing; the
   voice_turns metric already provides the per-surface lens. Revisit
   at Phase 18 when per-tenant economics matter.

## Cost impact (§4.5)

Budgets and their notifications: free. Net new recurring cost: zero.

## Consequences

- Audit finding #5 closes: the ceiling becomes an enforced signal
  with five graduated alerts to the same channels that page outages.
- The forecasted-breach alert gives days of warning on runaways
  instead of an invoice surprise.
- PR-4-COST closes on merge+apply; a TEST-project budget is noted
  for Phase 18.
- Implementation note: google_billing_budget operates at the
  BILLING-ACCOUNT level — the applying identity needs billing-account
  budget permissions (Billing Account Administrator/Costs Manager on
  the account, held by the Coordinator as owner). A permission error
  at apply is billing-account IAM, not project IAM.
