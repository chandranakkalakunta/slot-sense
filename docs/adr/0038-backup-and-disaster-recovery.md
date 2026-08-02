# ADR-0038: Backup & Disaster Recovery Strategy

- **Status:** Accepted
- **Date:** 2026-07-14
- **Phase:** Production Readiness / PR-1
- **Related:** ADR-0005 (cost ceilings), production-readiness baseline audit (2026-07-13), docs/backlog.md

## Context

The 2026-07-13 baseline audit measured live infrastructure against agreed
production-readiness targets and found **zero recovery capability for
Firestore** (PITR disabled, no backup schedules, no backups), unversioned
GCS buckets for Terraform state and invoice exports, and an incomplete
rebuild-from-Terraform path (baseline service accounts, their IAM
bindings, and the Cloud Run service are imperative-only). Effective RPO
was unbounded; a credible 4-hour RTO rebuild was not possible from code.

### Premises (fixed — set before this ADR, not re-litigated here)

- **RTO: 4 hours. RPO: 4 hours.** Backup-and-restore is sufficient; no
  continuous replication, hot standby, or multi-region failover.
- **Availability SLO: 99%** — single-region (asia-south1) is acceptable.
- **Restore scope: the COMPLETE application** — restoring data without
  secrets (or infra, or images) yields a non-functional app. All layers
  are in scope.
- **Cost ceilings (ADR-0005):** ₹5K/mo dev, ₹2K/tenant/mo prod.

## Decision

Backup-and-restore across six recovery layers, with one explicit
exclusion, all codified in Terraform where a resource is durable.

### Layer 1 — Firestore (system of record)

1. **PITR enabled** (7-day window) — *enacted 2026-07-14 as an immediate
   stop-gap ahead of this ADR; documented here per the phase plan.* Full
   7-day recovery depth accrues by 2026-07-21.
2. **Deletion protection enabled** (same stop-gap command) — suppresses
   the one disaster class PITR cannot survive, at zero cost.
3. **Daily scheduled backup, 7-day retention**, managed as a Terraform
   `google_firestore_backup_schedule` resource. Backups persist
   independently of the live database.

**Documented residual risk (accepted):** Firestore schedules support only
daily/weekly cadence, so the *database-deletion* disaster class has a
worst-case RPO of 24h, not 4h. All other classes (bad deploy, corrupting
write, application bug) recover via PITR with near-zero RPO inside the
7-day window. Accepted because (a) deletion protection makes the class
require two deliberate steps, and (b) the alternative — a 4-hourly
managed export to GCS — adds recurring document-read and storage cost
against ADR-0005 ceilings to mitigate a structurally suppressed scenario.

### Layer 2 — Secrets (Secret Manager)

**Runbook-based recovery; no out-of-band value backup.** Both current
secrets are re-issuable:

| Secret | Origin | Recovery procedure |
|---|---|---|
| `redis-auth` | Memorystore AUTH | Retrieve/regenerate via `gcloud redis instances get-auth-string` (or rotate AUTH), add new secret version |
| `resend-api-key` | Resend console | Re-issue key from provider console, add new secret version |

Terraform codifies secret **shells** (the `google_secret_manager_secret`
resources and their IAM) — never values, per protocol §2.6. The restore
runbook carries the inventory table above; any future secret MUST be
added to it in the same PR that introduces it, with its re-issue path,
or explicitly flagged as irreplaceable (which alone would justify
revisiting the no-value-backup decision).

### Layer 3 — Terraform-rebuildable infrastructure (IAM-TF-CODIFY)

Elevated from tech debt to **DR blocker**: a 4h RTO is not credible
until `terraform apply` can rebuild the project. The 2026-07-14 state
inventory confirmed Terraform already manages the LB/WAF/cert stack,
WIF, CI IAM, scheduler/tasks, two SAs, and the frontend + invoices
buckets. The measured gap to codify:

- **Four SAs** currently only `data` sources → convert to managed
  resources + import: `sa-cloud-run`, `sa-cloud-build`,
  `sa-firebase-admin`, `sa-monitoring` (`sa-scheduler-invoker` and
  `sa-tasks-invoker` are already managed).
- **~14 project-level IAM bindings** present in the live policy but
  absent from state (runtime, build, firebase-admin, monitoring, and
  `firebase-adminsdk-fbsvc` bindings), imported one-per-resource so git
  history stays a least-privilege audit trail (§4.11).
- **The Cloud Run service `sport-slot-api`** — imported as a managed
  resource with `lifecycle.ignore_changes` on the container image and
  deploy-client annotations. **Ownership model:** Terraform owns the
  service's existence and shape (the DR rebuild path); CI's imperative
  `gcloud` deploy remains the source of truth for revisions/images.
  Accepted trade-off: Terraform will not detect image drift — by
  design. (Alternatives — routing app deploys through Terraform, or
  leaving the service uncodified — rejected as deploy-coupling and a
  DR-story hole respectively.)
- **Firestore database** (codifying PITR + delete protection) and the
  **backup schedule** from Layer 1.
- **Secret shells** (`redis-auth`, `resend-api-key`) and the
  **`tfstate` bucket** (import + versioning per Layer 4).
- **The Memorystore Redis instance** — absent from state; the app
  fails closed without it, so a rebuild that omits it is not a
  rebuild. Import.
- **The Artifact Registry repository** (`sport-slot-repo`) — absent
  from state; Layer 5's CI image-rebuild path assumes it exists.
  Import.

Worker prepares `.tf` files and import commands and runs only
`fmt`/`validate`; **Coordinator runs every `import`/`plan`/`apply` and
reads the plans**. Risk-sensitive review tier (§3.5).

### Layer 4 — GCS buckets

**Versioning + lifecycle on `sport-slot-dev-tfstate` and
`sport-slot-dev-invoices`**, Terraform-managed. Lifecycle: retain a
bounded number of noncurrent versions (tfstate) / purge noncurrent
versions after 30 days (invoices) so versioning cannot accrete unbounded
storage cost. Invoices are immutable by design (ADR-0035); versioning
here protects against overwrite/deletion, not edits.

Dispositions per the 2026-07-14 inventory: `invoices` is already
Terraform-managed (versioning is a plain diff); `tfstate` is not in
state and is imported in the same change. **Explicit exclusions:**
`sport-slot-dev-frontend` (TF-managed, NOT versioned) and
`sport-slot-dev-cloudbuild` (left unmanaged AND unversioned) — both
hold rebuildable CI artifacts; versioning buys no recovery value and
costs noncurrent-version storage. All four buckets already carry 7-day
soft delete as a floor.

### Layer 5 — Container images

Artifact Registry images are rebuildable from git via CI (GitHub Actions
on merge to main). The restore runbook documents the rebuild path
(checkout → CI run or manual build → deploy) rather than replicating the
registry. Registry contents are additionally covered by the region's
availability; no cross-region copy at 99% SLO.

### Layer 6 — Firebase Auth identities

Firestore backups do **not** include Firebase Auth user accounts —
they are a separate store. Recovery: a documented
`firebase auth:export` / import procedure in the DR runbook, with a
stated manual export cadence, plus a backlog item to automate the
export to GCS later. Accepted interim residual: identities created
after the most recent export are lost under the project-loss class;
users re-register. Rejected alternative: treating Auth as out of
scope entirely — unacceptable for a system whose accounts belong to
real residents.

### Explicit non-goal — Redis

Memorystore Redis holds only ephemeral state by design: booking-slot
locks and password-reset tokens. It is **intentionally excluded from
backup scope** — restoring stale locks or expired tokens would be wrong,
not just unnecessary. Redis availability (BASIC-tier SPOF, fail-closed
behavior) is an *availability* question, addressed in the PR-3 ADR, not
a recovery question.

## Deliverable and proof

A **tested restore runbook** (`docs/runbooks/disaster-recovery.md`)
covering all six layers, executed end-to-end as a timed drill restoring
into a **separate scratch project** (zero blast radius; exercises the
true rebuild-from-nothing path), with the measured wall-clock time
recorded against the 4h RTO. An untested DR plan is not a DR plan.

## Alternatives considered

1. **Multi-region / hot standby / continuous replication** — rejected:
   contradicts the fixed premises (99% SLO, 4h RTO/RPO, cost ceilings).
2. **4-hourly Firestore managed export to GCS** — rejected for now:
   recurring read + storage cost to close a 24h→4h gap on a
   deletion-class scenario already suppressed by delete protection.
   Revisit if premises tighten.
3. **Out-of-band encrypted secret-value backup** — rejected: creates a
   second secret store that itself needs securing and rotation; both
   current secrets are re-issuable from their origin systems.
4. **Versioning all four GCS buckets** — rejected: frontend/cloudbuild
   artifacts are rebuildable; versioning them is pure cost.

## Cost impact (§4.5)

PITR retained-version storage + daily backup storage at current
(free-tier-scale) data volume: expected well under ₹100/mo combined.
GCS noncurrent-version storage bounded by lifecycle rules. No new
always-on compute. Comfortably inside the ₹5K/mo dev ceiling.

## Consequences

- RPO drops from unbounded to ~0 (PITR classes) / 24h documented
  residual (deletion class); RTO becomes provable via the timed drill.
- `terraform apply` becomes the authoritative rebuild path; future
  imperative resource creation is a regression against this ADR.
- Every new secret carries a runbook-inventory obligation.
- Backup-failure alerting is deliberately deferred to PR-2
  (observability), where it belongs with the rest of the alerting
  surface — logged on the backlog to prevent it falling between the
  two sub-phases.
