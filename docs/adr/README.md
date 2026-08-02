# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs)
for SportSlotReservation. ADRs capture the reasoning behind
significant architectural choices.

## What Are ADRs?

An Architecture Decision Record documents:
- **Context** — What problem are we solving?
- **Options** — What alternatives were considered?
- **Decision** — What did we choose?
- **Rationale** — Why did we choose it?
- **Consequences** — What does this commit us to?

ADRs are immutable historical records. They are not updated;
superseded ADRs link to their replacements.

## Phase 0 — Foundation Decisions

These ADRs were written before any code was committed,
establishing the architectural foundation.

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0001](0001-tech-stack.md) | Tech Stack & Software Versions | Accepted | Python 3.12 + FastAPI backend; React 18 + Vite + TypeScript + PWA frontend; Cloud Run with multi-stage Docker; uv + pnpm package managers; stateless architecture mandate |
| [0002](0002-database-technology.md) | Database Technology Selection | Accepted | Cloud Firestore Native Mode; Redis distributed locks for ACID-critical operations; per-country deployments for data sovereignty |
| [0003](0003-build-tooling.md) | Build Tooling Interface | Accepted | Makefile + bash hybrid; self-documenting via `make help`; safety guardrails for destructive operations |
| [0004](0004-tenant-isolation.md) | Tenant Isolation Strategy | Accepted | Logical isolation with 5-layer defense-in-depth; subdomain identification with wildcard DNS; platform admin assigns slugs |
| [0005](0005-cost-baseline.md) | Cost Baseline & Budget Alerts | Accepted | DEV ≤₹5K/month; PROD target ≤₹2K/tenant; 4-tier alert thresholds with hard limits at 100%; daily dashboard + weekly summary |

## Phase 2 — Backend API Foundation

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0006](0006-api-design-patterns.md) | API Design Patterns | Accepted | URL path versioning (/api/v1/); UPPER_SNAKE error code registry; cursor-based pagination only; split /health + /readyz probes (/healthz is GCP-reserved) |
| [0007](0007-auth-and-authorization.md) | Authentication & Authorization | Accepted | firebase-admin only JWT verification (python-jose prohibited); custom claims as identity source of truth; accepted 1h staleness with selective revocation; no admin tenant bypass; phased rate limiting |
| [0008](0008-data-layout-and-repository-contract.md) | Data Layout & Repository Contract | Accepted | Permanent deny-all Firestore rules; per-tenant subcollection layout /tenants/{id}/...; TenantRepository with construction-time tenant enforcement; PlatformRepository gated to platform_admin; cursor pagination |

## Phase 3 — Booking Engine

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0009](0009-slot-locking-redis.md) | Slot Locking — Memorystore Redis | Accepted | Memorystore Redis Basic 1 GB; SET NX PX lock on deterministic key; Fail Closed (503 on Redis down, never bypass); LockService interface; VPC egress to Cloud Run |
| [0010](0010-booking-domain-and-policy.md) | Booking Domain Model & Policy Resolution | Accepted | Computed availability (no pre-generated slots); deterministic booking ID as second double-booking guard; PolicyService Tenant Override → Global Default; quota enforcement inside Firestore transaction |
| [0011](0011-audit-logging.md) | Audit Logging | Accepted | Append-only Firestore audit events at /tenants/{id}/audit; synchronous write in mutation path; BigQuery prohibited in request path; Cloud Logging rejected as non-tenant-owned |

## Phase 4 — Frontend PWA

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0012](0012-frontend-architecture.md) | Frontend Architecture | Accepted | Classic Firebase Hosting (named subdomains, LB wildcard deferred to Phase 7); same-origin API via Hosting rewrites (zero CORS); React 18 + Vite + TS strict + TanStack Query; CSS variables as tenant theming contract; Tailwind rejected |
| [0013](0013-error-presentation-i18n.md) | Error Presentation & i18n Strategy | Accepted | Resolver chain: tenant override → locale catalog → English default → raw code; English-only catalog in Phase 4.3; locale/tenant-override layers designed-for but not built; fail-safe renders the code itself on unmapped entry |

## Phase 5 — Admin & Provisioning

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0014](0014-admin-architecture-identity.md) | Admin Architecture & Identity | Accepted | Route-gated admin surfaces (/admin/*, /tenant/*) in the existing PWA; seeded first superadmin; generate+force-change credential model; must_change_password flag + forced-reset screen; require_platform_admin dependency |
| [0015](0015-facility-catalog-model.md) | Facility Catalog Model | Accepted | Global platform catalog at /facility_catalog/{type_id} seeded with standard sports; per-tenant facility instances gain facility_type_id; catalog CRUD deferred; creation constraint enforces type selection |
| [0016](0016-user-provisioning.md) | Bulk & Manual User Provisioning | Accepted | Single UserProvisioningService.create_user() for all paths; CSV schema with partial-success import; household_id derived from flat_number; frontend parses CSV (backend stays file-agnostic); 500-row cap |
| [0017](0017-deletion-retention-lifecycle.md) | Deletion, Retention & Lifecycle | Accepted | Three-stage tenant lifecycle ACTIVE→INACTIVE→PURGED; user soft-delete with Firebase Auth disable + cancel future bookings; self-deactivation forbidden; audit trail preserved through INACTIVE period |
## Phase 6 — Keyless CI/CD

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0018](0018-cicd-security-model.md) | CI/CD Security Model — Keyless Deploys via Direct WIF | Accepted | No static service-account keys anywhere; Workload Identity Federation with direct principalSet IAM bindings; deploy pipeline authenticates via WIF, not JSON credentials |

## Multi-env ops & quality (post-17)

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0045](0045-test-strategy-and-environment-promotion.md) | Test Strategy & Environment Promotion | Accepted | Layered suites (static, unit regression, smoke, functional, perf); same-SHA progressive promote CI→dev→test→prod; prod human approval; runbook in docs/testing/TEST-STRATEGY.md |

## Phase 7 — Notifications & Self-Service Password Reset

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0019](0019-notification-architecture.md) | Notification & Email Architecture | Accepted | Resend + Cloud Tasks async dispatch; code-owned email templates; best-effort delivery that never blocks the mutation that triggered it |
| [0020](0020-password-reset-and-policy.md) | Self-Service Password Reset & Password Policy | Accepted (amended 2026-06-21) | Token-based self-service reset flow; password strength policy; integrates with ADR-0019's notification pipeline |

## Phase 9 — AI Booking Agent

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0021](0021-ai-booking-agent-architecture.md) | AI Booking Agent — Architecture | Accepted (2026-07-07 — confirmed live in production) | Vertex AI Gemini 1.5 Pro function calling; 5 tools; two-turn interaction pattern; tenant-scoped throughout |
| [0022](0022-ai-booking-agent-guardrails.md) | AI Booking Agent — Guardrails & Safety | Accepted (2026-07-07 — confirmed live in production) | Fail-closed safety architecture for an agent that mutates real booking state |
| [0023](0023-propose-confirm-execute-gate.md) | Propose-Confirm-Execute Gate for the AI Booking Agent | Accepted | The agent never directly mutates state; every action requires a Redis-backed pending proposal the user explicitly confirms |
| [0024](0024-output-guard-hallucination-detection.md) | Output Guard for LLM Hallucination Detection | Accepted | Second Vertex call validates every entity reference in a natural-language reply actually exists for the current tenant; fails closed |
| [0025](0025-pending-action-store.md) | Pending Action Store (Redis-backed, single-use, secondary pointer) | Accepted (extended slice 6.5c) | 5-minute TTL pending-action mechanism underlying the propose-confirm-execute gate |
| [0026](0026-deterministic-python-guards.md) | Deterministic Python Guards over LLM Judgment | Accepted | Temporal reasoning, quota counting, and disambiguation matching handled by deterministic code, not LLM judgment |
| [0027](0027-stateful-cancel-disambiguation.md) | Stateful Cancel Disambiguation via Pending Action Store | Accepted | Extends the pending-action store with a cancel-specific action type and conservative date/time substring matching |

## Phase 10 — UI Redesign + PWA Mobile Validation

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0028](0028-frontend-design-system-and-theming.md) | Frontend Design System and Theming | Accepted (2026-07-07 — confirmed live in production) | Tailwind v4 + shadcn/ui + Radix adoption; extends ADR-0012/0013's original frontend architecture |
| [0029](0029-pwa-co-branding-hierarchy.md) | PWA Co-Branding Hierarchy | Accepted | Formalized visual hierarchy for platform branding alongside per-tenant branding |

## Booking-Model v2 (unnumbered phase)

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0030](0030-booking-model-v2-weekly-schedule.md) | Booking-Model v2 — Weekly Multi-Range Facility Schedule | Accepted | Multi-range per-day-of-week facility schedules, replacing a single fixed daily open/close range |

## Phase 8 — Production Networking

*Note: this phase shipped after Phase 9 and 10 (a deliberate roadmap
choice — see the Phase 9 retrospective), which is why its ADR numbers
are higher than Phase 9/10's despite the "Phase 8" name. Sections above
are ordered by ADR number, per this document's own numerical reading
order.*

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0031](0031-load-balancer-wildcard-subdomains.md) | Global External HTTPS Load Balancer + Wildcard Subdomain Routing | Accepted | Real wildcard subdomain routing via Certificate Manager + DNS authorization, deferred since ADR-0012 |
| [0032](0032-cloud-armor-preview-mode.md) | Cloud Armor WAF, Preview Mode | Accepted | Edge + API WAF policies in log-only preview mode; enforcement deferred pending real traffic data |
| [0033](0033-dev-web-app-path-deprecated.md) | Deprecate sport-slot-dev.web.app API Path; Restrict Cloud Run Ingress | Accepted | Cloud Run ingress restricted to internal-and-LB traffic; accepted DEV-only tradeoff on the legacy Firebase Hosting path |

## Phase 13 — Entity Lifecycle Management

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0034](0034-facility-lifecycle-and-dpdp-erasure.md) | Facility Lifecycle, Direct Entity Deletion & DPDP-Compliant Erasure | Accepted | Extends ADR-0017: facility Delete-only lifecycle (no Deactivate/PURGED stage), and a direct, independent Delete action for residents/tenant-admins/tenants, superseding ADR-0017's never-implemented 90-day PURGE script for the on-demand case |


## Phase 15 — Billing & Invoicing

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0035](0035-billing-invoicing-architecture.md) | Billing & Invoicing Architecture | Accepted | Optional flat-rate per-facility pricing (integer paise); postpaid monthly billing, fixed day, admin-configurable time only; immutable create-only invoices with deterministic IDs for idempotent re-runs; payment status fully external, never tracked; household-level billing resolved directly from bookings, with flat_number/resident_name denormalized at generation time; keyless GCS export (summary-level only, not the system of record) via self-impersonated signed URLs; two independent manual recovery triggers; tenant-admin visibility evolved from latest-only to history + live current-month preview; read-only agent invoice tools with deterministic pre-Vertex routing (extends ADR-0026) after a live-reproduced Gemini tool-selection reliability bug; implements ADR-0034's invoice-exclusion carve-out via dynamic subcollection enumeration |

## Phase 16 — Voice I/O

*Note (added 2026-07-16, DOC-TRUTH): the CHANGELOG tracks this work as
unprefixed "Voice I/O sub-phase 1a/1b/1c/2" entries, not literally
"Phase 16.x" — the phase number here is inferred from three
independent forward-references to "Phase 16 DPDP self-assessment" in
ADR-0036, ADR-0037, and `docs/backlog.md`, plus the Phase 13
retrospective naming Voice I/O as the second of "two new phases...
locked in sequence" after Phase 13. Flagged, not asserted as
certain — correct this note if the Strategist's records show
otherwise.*

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0036](0036-voice-io-for-ai-booking-assistant.md) | Voice I/O for the AI Booking Assistant | Approved | Speech-to-text/text-to-speech at the edges of the existing text agent (ADR-0021), zero changes to the agent core; translate-at-the-edges design; deterministic confirm/deny guard extends ADR-0026 |
| [0037](0037-voice-language-detection-per-tenant.md) | Voice Language Detection — Per-Tenant Candidate Set | Accepted | Supersedes ADR-0036 §D3 (full 9-language auto-detect) after `chirp_3` STT model GA-revocation discovered live; per-tenant candidate set instead; revises ADR-0036 §D5 residency, carrying a residency exception into the Phase 16 DPDP self-assessment |

## Phase 17 — Production Readiness

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0038](ADR-0038-backup-and-disaster-recovery.md) | Backup & Disaster Recovery Strategy | Accepted | Six-layer DR runbook (Firestore, Secrets, Terraform rebuild, GCS, container images, Firebase Auth) at 4h RTO/RPO; Firestore PITR + delete protection; daily backup schedule; Terraform codification of previously-imperative SAs/IAM/Cloud Run/Redis/Artifact Registry (PR-1a, PR-1b) |
| [0039](ADR-0039-accepted-production-hardening-residuals.md) | Accepted Production-Hardening Residuals | Accepted | CMEK, VPC+NAT for Cloud Run, admin MFA, and penetration testing deferred as a single dated accepted-residual decision (not four silent open items), with explicit revisit triggers |
| [0040](ADR-0040-observability-and-alerting.md) | Observability & Alerting Baseline | Accepted | Two notification channels (Email + console-owned SMS), uptime checks (edge + service path), four alert policies (5xx rate, p95 latency, uptime failure, backup failure), Error Reporting, voice/agent turn-counter log-based metrics — all Terraform creates, no imports (PR-2) |
| [0041](ADR-0041-availability-slo-redis.md) | Availability, SLO Formalization & the Redis Decision | Accepted | Cloud Run `maxScale` 2→10, TCP→HTTP startup probe, added liveness probe; 99% monthly SLO formalized at doc level (no Monitoring SLO API resources yet, gated behind `SLO-LOAD-TEST`); Redis `BASIC` tier affirmed as a documented residual with revisit triggers; "SlotSense Ops" Terraform-managed dashboard (PR-3) |
| [0042](ADR-0042-cost-guardrails.md) | Cost Guardrails — Billing Budget & Thresholds | Accepted | One Terraform-managed, alert-only `google_billing_budget` for `sport-slot-dev`, ₹5K/mo ceiling (ADR-0005) with five graduated thresholds (50/80/100/120% actual + 100% forecasted), routed to the existing ADR-0040 channels; automated billing-disable/service-cap response explicitly rejected (PR-4) |
| [0043](ADR-0043-security-hardening.md) | Security Hardening | Accepted | Split by blast radius: PR-5a (headers, CI scanning, registry cleanup, rotation policy), PR-5b (WIF least-privilege; Armor enforce gated on a preview-log review), PR-5c (Armor API-policy SQLi/XSS enforced with a voice-path exemption, option 2 — accepted residual `VOICE-INPUT-VALIDATION` tracked for Phase 18). Closes finding #7, the last of the ten 2026-07-13 audit findings. Binary Authorization explicitly deferred to Phase 18 |

## Reading Order

For someone new to the project, read ADRs in numerical order.
Each builds on previous decisions.

## Writing a New ADR

1. Copy `template.md` to `NNNN-short-name.md` (next sequential number)
2. Fill in all sections
3. Set status to "Proposed" initially
4. Open a Pull Request for discussion
5. After discussion, update status to "Accepted" and merge
6. Never modify an accepted ADR — write a superseding one instead

## ADR Statuses

- **Proposed** — Under discussion, not yet decided
- **Accepted** — Decision made and being implemented
- **Superseded by ADR-NNNN** — Replaced by a newer ADR
- **Deprecated** — No longer recommended, but not actively replaced
- **Rejected** — Considered and explicitly not adopted

## Related Documentation

- [Project README](../../README.md) — Project overview
- [Runbooks](../runbooks/) — Operational procedures
- [Diagrams](../diagrams/) — Architecture visualizations (future)
