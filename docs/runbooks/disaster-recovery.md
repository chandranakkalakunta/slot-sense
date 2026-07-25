# Disaster Recovery Runbook

- **Status:** Layers 1–6 complete (PR-1a, PR-1b) — procedures below
  are complete where facts are known; drill execution and
  TODO-Coordinator items are outstanding.
- **Governing ADR:** [ADR-0038](../adr/ADR-0038-backup-and-disaster-recovery.md)
- **Last updated:** 2026-07-25

## 1. Scope, RTO/RPO, disaster classes

**RTO: 4 hours. RPO: 4 hours** (fixed premises, ADR-0038). Restore
scope is the **complete application** — data, secrets, infrastructure,
images, and identities. Restoring any one layer without the others
yields a non-functional app.

### Disaster classes in scope

| Class | Example | Primary defense |
|---|---|---|
| Corrupting write / application bug | Bad migration writes wrong data | Firestore PITR (near-zero RPO, 7-day window) |
| Bad deploy | Broken revision serving traffic | Cloud Run revision rollback; image rebuild (Layer 5) |
| Accidental/malicious deletion | Document or collection deleted | Firestore PITR |
| Database deletion | `(default)` database deleted | Delete protection (primary); daily backup schedule (worst-case 24h RPO — accepted residual, see ADR-0038) |
| Project loss | Project deleted/compromised | Full rebuild across all six layers into a new project |
| Secret loss/rotation need | Secret value compromised or lost | Layer 2 runbook-based re-issue (secrets are not backed up as values) |

### Explicit non-goal

Memorystore Redis (ephemeral locks/tokens) is **out of scope** —
restoring stale locks or expired tokens is wrong behavior, not missing
behavior. See ADR-0038 "Explicit non-goal — Redis."

The BASIC-tier (single-node, no persistence) SPOF this implies is a
**documented, accepted residual with revisit triggers**, not an
unexamined risk — see [ADR-0041 D16](../adr/ADR-0041-availability-slo-redis.md#d16--redis-basic-tier-accepted-as-documented-residual)
and backlog `REDIS-HA-TRIGGERS`.

## 2. Layer 1 — Firestore

### 2.1 PITR restore (preferred — corrupting write, bad deploy, accidental deletion)

PITR gives point-in-time recovery within the current retention window
(7 days once full depth accrues by 2026-07-21).

1. Identify the target restore timestamp (before the corrupting event).
2. Restore to a **new** database (PITR restore cannot overwrite the
   live `(default)` database in place):
   ```
   gcloud firestore databases restore \
     --source-database='(default)' \
     --destination-database=<restore-target-db-id> \
     --snapshot-time=<RFC3339 timestamp> \
     --project=sport-slot-dev
   ```
3. Validate restored data in `<restore-target-db-id>`.
4. Cut the application over to the restored database (config/env
   change), or export/import the needed collections back into
   `(default)` if a partial restore is preferred.
5. Decommission the scratch restore database once cutover is
   confirmed.

> **TODO-Coordinator:** confirm current GCP documentation for whether
> PITR restore can target the *same* database in place vs. requiring a
> new destination database — this procedure assumes new-database-only
> based on current understanding; verify before the timed drill.

### 2.2 Backup restore (database-deletion class only)

Daily backups (7-day retention) are the fallback when PITR itself is
unavailable — i.e., the database was deleted outright.

1. List available backups:
   ```
   gcloud firestore backups list --project=sport-slot-dev
   ```
2. Restore a backup to a new database:
   ```
   gcloud firestore databases restore \
     --source-backup=<backup-id> \
     --destination-database=<restore-target-db-id> \
     --project=sport-slot-dev
   ```

> **TODO:** Firestore backup restore is believed to be
> **same-project-only** (cannot restore a backup into a different GCP
> project). Verify against current GCP docs during drill design. If
> confirmed, the **project-loss** disaster class cannot use backup
> restore at all — Layer 1 recovery for project-loss depends on
> whichever layer-4/5 rebuild lands data into the new project first,
> or on the cross-project alternative below.

**Cross-project alternative (for project-loss class):** Firestore
managed export/import (`gcloud firestore export` / `import`) to/from a
GCS bucket works across projects, unlike backup restore. This path is
not currently scheduled (see ADR-0038 "Alternatives considered" — a
4-hourly export was rejected on cost grounds), but remains available
as a manual step during a project-loss drill or real recovery: export
from the surviving artifact (if any) or accept the daily-backup RPO
and re-import into the new project's database.

## 3. Layer 2 — Secrets

No out-of-band value backup exists (ADR-0038 §Layer 2). Recovery is
runbook-based re-issue, then Terraform-imported shell + a new secret
version added by the Coordinator (secret values are never handled by
automation per protocol §2.6).

| Secret | Origin | Recovery procedure |
|---|---|---|
| `redis-auth` | Memorystore AUTH string | `gcloud redis instances get-auth-string <instance> --region=asia-south1 --project=sport-slot-dev` (or `gcloud redis instances update --enable-auth` to force-rotate), then `gcloud secrets versions add redis-auth --data-file=-` |
| `resend-api-key` | Resend console | Re-issue key from the Resend dashboard, then `gcloud secrets versions add resend-api-key --data-file=-` |

**Obligation:** any new secret introduced to this project MUST be
added to this table in the same PR that introduces it, with its
re-issue path — or be explicitly flagged as irreplaceable (which would
itself justify revisiting the no-value-backup decision).

### 3.1 Secret rotation policy (ADR-0043 PR-5a)

Policy + manual procedure only — no automation. Builds on the
recovery inventory above; rotation reuses the same re-issue commands,
plus the two steps recovery doesn't need (redeploy, retire old
version).

**Cadence:**
- **Event-driven (immediate):** suspected or confirmed compromise —
  leaked value, departing operator with access, anomalous usage.
  Rotate the same day.
- **Periodic:** quarterly review at this dev-stage, single-operator
  project (proportionate to current risk — see security charter
  §Threat Model). Revisit toward a shorter cadence at the first
  paying tenant / Phase 18 production launch.

**Procedure (both secrets):**

1. **Generate/re-issue** the new value — same commands as the
   recovery table above:
   - `redis-auth`: `gcloud redis instances get-auth-string <instance> --region=asia-south1 --project=sport-slot-dev` (retrieves current) or `gcloud redis instances update --enable-auth` (forces a new AUTH string)
   - `resend-api-key`: re-issue from the Resend console
2. **Add a new Secret Manager version** (does not touch or invalidate
   the old version yet): `gcloud secrets versions add <secret-id> --data-file=-`
3. **Redeploy and verify.** Both secrets are wired into
   `google_cloud_run_v2_service.sport_slot_api` with `version =
   "latest"` (`terraform/cloud_run.tf:163,172`) — but Cloud Run
   resolves `"latest"` **once, at revision start**, not per-request.
   Adding a version alone does **not** reach already-running
   instances; a new revision must actually roll out (redeploy, or
   force a new revision) before the rotation takes effect. Verify
   post-rollout: `redis-auth` — confirm the app still connects (no
   `AUTH` failures in logs / Redis-dependent endpoints healthy);
   `resend-api-key` — send one test email and confirm delivery.
4. **Disable the old version** only after step 3 verifies clean —
   `gcloud secrets versions disable <secret-id> --version=<old-version>`.
   Disable, not destroy: keeps a fast rollback path (re-enable) if the
   rotation surfaces a problem after the fact. Destroy the disabled
   version on the next periodic review once confident it's unneeded.

## 4. Layer 3 — Terraform rebuild

PR-1b codifies the remaining imperative-only resources (four service
accounts, 16 project-level IAM bindings, the Cloud Run service, the
Memorystore Redis instance, the Artifact Registry repository) so that
`terraform apply` is a credible from-scratch rebuild path into a new
project. See ADR-0038 §Layer 3 for the design rationale.

### 4.1 Rebuild procedure (new project)

**Primary path:** `scripts/drill-bootstrap.sh` (PR-G) encodes every step
below into one idempotent, resumable command — run
`scripts/drill-bootstrap.sh --help` for usage, or `--dry-run` to see the
plan without touching gcloud/terraform/firebase. It writes a
`bootstrap-output-<project_id>-<timestamp>.md` manifest (gitignored) with
the LB IP, DNS records, Cloud Run URL, admin credentials, and the
`scripts/tf.sh` registry entry to add. The manual steps below remain the
documented fallback and the source of truth the script implements — use
them if the script itself needs debugging, or for any step it doesn't
cover (DNS, cert wait, per-env CI wiring).

Order matters — several steps have a bootstrapping dependency on the
step before them.

1. **Create the project and link billing.**
   ```
   gcloud projects create <new-project-id> --organization=<org-id>
   gcloud billing projects link <new-project-id> --billing-account=<billing-account-id>
   gcloud config set project <new-project-id>
   ```
2. **Enable the APIs `terraform/apis.tf` expects to already be on**
   (the `google_project_service` resources in that file assume the
   API-enablement API itself and a few bootstrap APIs are already
   active):
   ```
   gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com
   ```
3. **Create the Terraform state bucket manually** — the backend
   (`terraform/backend.tf`, GCS) cannot bootstrap the bucket it
   stores its own state in:
   ```
   gcloud storage buckets create gs://<new-project-id>-tfstate \
     --location=asia-south1 --uniform-bucket-level-access
   gcloud storage buckets update gs://<new-project-id>-tfstate --versioning
   ```
   Update `terraform/backend.tf`'s bucket name (or pass `-backend-config`)
   to point at it, then `terraform init`.
4. **Add Firebase to the project** before any `terraform apply` that
   touches Firebase-adjacent IAM — this is what provisions the
   `firebase-adminsdk-fbsvc@` service account and its 3 bindings (D8
   exclusion; see §4.2), which Terraform does not and cannot create:
   ```
   firebase projects:addfirebase <new-project-id>
   ```
   Email/Password sign-in is now codified as
   `terraform/auth.tf`'s `google_identity_platform_config.auth`
   (PR-F, closes GAP 2.2) — no manual console/CLI step is needed for
   a **new** environment; it's created by the bootstrap-group apply
   (step 6) via `identitytoolkit:initializeAuth`, the same API that
   already backs standard Firebase Auth (no GCIP tier upgrade — see
   `auth.tf`'s header comment for the verification). An **existing**
   environment that already has a live Config object (e.g.
   sport-slot-dev) needs a one-time
   `terraform import google_identity_platform_config.auth <project-id>`
   before its first plan/apply including this resource, so Terraform
   adopts it instead of attempting to re-initialize it.
5. **SMS notification channel — OPTIONAL, deferred by default**
   (ADR-0040 PR-2; made conditional in PR-F, closes GAP 2.3). New
   environments build **email-only**: `terraform/observability.tf`'s
   SMS lookup is gated behind `var.enable_sms_alerts` (default
   `false`), so an unconfigured environment's plan/apply no longer
   fails on a missing console-created channel. Skip this step for a
   new environment's first apply.
   To add SMS later, once ready: Console → Monitoring → Alerting →
   Notification Channels → Add SMS, display name exactly
   `Coordinator SMS`, complete the one-time verification code (see
   `docs/runbooks/observability.md`), then set
   `enable_sms_alerts = true` in that environment's tfvars before the
   next apply. Legacy `sport-slot-dev` already has the channel — its
   tfvars (gitignored) must set `enable_sms_alerts = true` or its
   alert policies silently drop the SMS channel on the next apply.
   (The email channel and everything else in `observability.tf` is
   unconditionally Terraform-managed — nothing else to pre-create.)
6. **Bootstrap-group `terraform apply`, excluding Cloud Run:**
   ```
   terraform apply -target=<every resource except google_cloud_run_v2_service.sport_slot_api>
   ```
   This is required because `google_cloud_run_v2_service.sport_slot_api`
   references a container image
   (`asia-south1-docker.pkg.dev/.../sport-slot-repo/sport-slot-api:<tag>`)
   that cannot exist yet in a brand-new Artifact Registry repo — the
   repo, the Cloud Build staging bucket
   (`google_storage_bucket.cloudbuild_staging`), and the Cloud Build
   SA IAM bindings are all created in this same apply pass (DR drill
   Pass 1, findings #2 and #8). `scripts/setup_build_infra.sh` — the
   imperative script that previously granted `sa-cloud-build`'s
   bucket-level `storage.objectAdmin` on the staging bucket (hardcoded
   to `sport-slot-dev`, never codified) — is retired 2026-07-25 by
   PR-I; that binding is now
   `google_storage_bucket_iam_member.cloud_build_staging_object_admin`
   in `terraform/iam.tf`, created in this same apply pass. Terraform cannot create a Cloud Run
   revision pointing at an image that doesn't exist.
7. **Build and push at least one image** into the newly created
   `sport-slot-repo`, e.g. via a manual `gcloud builds submit --tag
   asia-south1-docker.pkg.dev/<new-project-id>/sport-slot-repo/sport-slot-api:bootstrap`,
   or by pointing CI (once its WIF federation is live from step 6) at
   the new project and letting the normal pipeline deploy.
8. **Populate Secret Manager secret versions — hard prerequisite,
   BEFORE the Cloud Run apply.** Terraform creates secret *shells*
   only, never values (see §3 for each secret's re-issue procedure).
   > **Warning (DR drill Pass 1, finding #7):** creating the Cloud Run
   > service before secret values exist leaves it **tainted**
   > (`SECRETS_ACCESS_CHECK_FAILED`) — and `prevent_destroy` then
   > blocks Terraform from self-healing, requiring a manual
   > `terraform untaint` plus a forced revision to recover. Populate
   > secrets first; there is no cheaper recovery path once this
   > happens.
9. **Second `terraform apply` pass**, with `google_cloud_run_v2_service.sport_slot_api`
   included, now that its image exists AND its secrets are populated.
   Per the D7 ownership model (`terraform/cloud_run.tf`), Terraform
   only needs *an* image to exist at this point — CI owns which image
   is live from then on.
   > **Note:** the org-policy exception permitting the public
   > (`allUsers`) frontend bucket binding needs roughly 1–2 minutes to
   > propagate after this apply creates it. If the binding step 412s,
   > wait and retry — this is expected, not a failure (DR drill Pass 1,
   > finding #10).
10. **Manual post-apply steps:**
    - Grant `roles/iam.serviceAccountUser` on `sa-scheduler-invoker` to
      whichever principal is running `terraform apply`, if the apply
      fails on an actAs-style permission error (see the NOTE in
      `terraform/cloud_scheduler.tf`).
    - Restore Firestore data (Layer 1) and Firebase Auth identities
      (Layer 6) into the new project.
    - Repoint DNS (§8) at the new Load Balancer's static IP once
      `terraform apply` has created it.
11. **Verify:** `terraform plan` shows no changes, the Cloud Run
    service serves traffic, and CI can deploy a new revision
    end-to-end.

### 4.2 Managed vs excluded inventory

Every asset type live in `sport-slot-dev` as of the 2026-07-16
completeness check (PR-1b Step 6), classified as Terraform-managed,
runbook-covered, or explicitly excluded:

| Asset | Classification | Note |
|---|---|---|
| `google_service_account`: sa-cloud-run, sa-cloud-build, sa-firebase-admin, sa-monitoring | TF-managed | `terraform/iam.tf` (PR-1b) |
| `google_service_account`: sa-scheduler-invoker, sa-tasks-invoker | TF-managed | `terraform/cloud_scheduler.tf`, `terraform/cloud_tasks.tf` (pre-existing) |
| 16 project IAM bindings on the 6 custom SAs above | TF-managed | `terraform/iam.tf` (PR-1b) |
| `firebase-adminsdk-fbsvc@` service account | **Excluded** | Firebase-provisioned automatically by `firebase projects:addfirebase` — no Terraform resource can create it; recreated by rebuild step 4.1.4 |
| 3 bindings on `firebase-adminsdk-fbsvc@` (`firebase.sdkAdminServiceAgent`, `firebaseauth.admin`, `iam.serviceAccountTokenCreator`) | **Excluded (D8)** | Firebase-provisioned alongside the SA above; not codified per Coordinator-approved D8 scope decision |
| `707808711911-compute@developer.gserviceaccount.com` (default Compute Engine SA) | **Excluded** | GCP-default per-project SA, auto-created — **not unused**: it is Cloud Build's default identity in new projects (`roles/cloudbuild.builds.builder` granted to `<project_number>-compute@`, DR drill Pass 1 finding #2), so Cloud Build fails without it present and correctly bound |
| All `service-*@gcp-sa-*.iam.gserviceaccount.com` / `*.gserviceaccount.com` service agents (cloudbuild, cloudservices, cloud-redis, compute-system, container-engine-robot, containerregistry, firebase-rules, aiplatform, artifactregistry, cloudscheduler, cloudtasks, firebase, firestore, pubsub, serverless-robot-prod) | **Excluded** | Google-provisioned service agents, created automatically when the corresponding API is enabled; no Terraform resource represents them; reappear automatically on API enablement during rebuild |
| `google_cloud_run_v2_service.sport_slot_api` | TF-managed | `terraform/cloud_run.tf` (PR-1b); existence/shape only — see D7 |
| Cloud Run **revisions** | **Excluded** | CI-owned per D7; ephemeral, not individually tracked; ignored via `lifecycle.ignore_changes` on the image/client fields |
| `google_redis_instance.sport_slot_redis` | TF-managed | `terraform/base_infra.tf` (PR-1b) |
| `google_artifact_registry_repository.sport_slot_repo` | TF-managed | `terraform/base_infra.tf` (PR-1b) |
| `google_firestore_database.default` + daily backup schedule | TF-managed | `terraform/backup_dr.tf` (PR-1a) |
| `google_secret_manager_secret`: redis-auth, resend-api-key (shells) | TF-managed | `terraform/backup_dr.tf` (PR-1a); values are runbook-covered, see §3 |
| GCS: `sport-slot-dev-tfstate`, `sport-slot-dev-invoices`, `sport-slot-dev-frontend` | TF-managed | `backup_dr.tf`, `invoice_export.tf`, `load_balancer_backends.tf` |
| GCS: `sport-slot-dev-cloudbuild` | **Excluded** | Auto-created Cloud Build staging bucket; rebuildable CI artifact, no recovery value (see §5) |
| `google_cloud_scheduler_job.invoice_generation` | TF-managed | `terraform/cloud_scheduler.tf` (pre-existing) |
| `google_cloud_tasks_queue` (notifications) | TF-managed | `terraform/cloud_tasks.tf` (pre-existing) |
| Load Balancer, Cloud Armor, networking | TF-managed | `load_balancer_*.tf`, `cloud_armor.tf` (pre-existing) |
| WIF pool/provider (GitHub Actions OIDC) | TF-managed | `wif.tf`, `wif_iam.tf` (pre-existing) |
| `google_identity_platform_config.auth` (Email/Password sign-in provider) | TF-managed (PR-F) | `terraform/auth.tf`; sport-slot-dev requires a one-time import (see step 4.1.4) since the object pre-dates this resource |
| Firebase project config, Hosting | **Runbook-covered** | Managed via Firebase CLI/Console, not Terraform (see step 4.1.4, Layer 6, and `terraform/firestore.tf`'s note on security rules) |
| Firebase Auth user identities | **Runbook-covered** | See §7 |
| DNS records (Namecheap) | **Runbook-covered** | External registrar, not a GCP asset; see §8 |

> Compiled by reasoning over the repo's `.tf` files against a live
> per-service inventory (`gcloud storage/secrets/iam/run/scheduler/
> tasks/firestore/artifacts/redis list`), since `gcloud asset
> search-all-resources` requires enabling `cloudasset.googleapis.com`,
> which this PR does not do (zero-live-change scope; enabling it is a
> live project change left for the Coordinator if a full asset-graph
> view is wanted later).

### 4.3 `scripts/tf.sh` — environment-safe Terraform wrapper

**Why this exists:** Terraform selects its **state** (backend, via
`-backend-config`, cached silently in `.terraform/`) and its
**variables** (via `-var-file`, per command) through two independent
mechanisms that can disagree with no warning — a backend block cannot
itself take variables, so there is no Terraform-native way to bind the
two together. This is exactly what happened during the 2026-07 DR
drill: `.terraform/` was still pointed at the drill project
(`slot-sense-dev-01`) from an earlier `init`, while a plain `terraform
plan` picked up `terraform.tfvars` (`sport-slot-dev`). Terraform
correctly produced a plan to **destroy 95 drill resources and recreate
them as dev resources** — only `lifecycle.prevent_destroy` and a human
reading the plan caught it (DR Drill Pass 1, finding #4 in
"Local environment hazards observed").

`scripts/tf.sh` makes environment selection **atomic**: one argument
selects both the backend and the var-file, no `terraform` command runs
without naming an environment, and every invocation refuses to proceed
if the live state's `project_id` output doesn't match what the named
environment expects.

**Usage:**

```
scripts/tf.sh <env> <terraform-command> [args...]
scripts/tf.sh --list
scripts/tf.sh --help
```

```
scripts/tf.sh dev plan
scripts/tf.sh dev-01 apply -target=google_project_service.enabled_apis
scripts/tf.sh dev import google_storage_bucket.foo my-bucket
```

Or via `make`: `make tf ENV=dev CMD=plan`, `make tf-list`.

**What it does on every invocation:**

1. Looks up `<env>` in the registry at the top of `tf.sh` (currently
   `dev` → `sport-slot-dev`, `dev-01` → `slot-sense-dev-01`) — an
   unknown environment or a missing `-var-file` refuses to run
   anything.
2. Compares the bucket recorded in `.terraform/terraform.tfstate`
   (the local backend pointer) against the environment's expected
   bucket, and re-runs `terraform init -reconfigure -backend-config=...`
   whenever they differ — the exact drift that caused the drill
   incident.
3. Runs `terraform output -raw project_id` against the now-correct
   backend and **hard-refuses** to run the requested command if it
   doesn't match the environment's expected project — a second,
   independent check against the live state itself, not just against
   where `.terraform/` is pointed.
4. Auto-injects `-var-file=<env's tfvars>` for commands that accept it
   (`plan`, `apply`, `destroy`, `refresh`, `import`, `console`); passing
   `-var-file` manually is rejected — the whole point is that you never
   choose it separately from the environment.

**Adding a new environment:** add one `case` arm to `env_lookup()` in
`scripts/tf.sh` — project ID, state bucket, prefix, and var-file all
live in that one place.

**Note:** `terraform/slot-sense-dev.tfvars` (the first drill attempt,
project now `DELETE_REQUESTED`) is deliberately **not** in the
registry — it points at a project that no longer exists.

## 5. Layer 4 — GCS buckets

Versioned buckets: `sport-slot-dev-tfstate`, `sport-slot-dev-invoices`.
(`sport-slot-dev-frontend` and `sport-slot-dev-cloudbuild` are
explicitly excluded — rebuildable CI/deploy artifacts, no recovery
value from versioning; see ADR-0038 §Layer 4.)

### Restore a specific object version

1. List versions of the affected object:
   ```
   gcloud storage ls -a gs://<bucket>/<object>
   ```
2. Copy the desired noncurrent version back over the current object
   (or to a new path for review first):
   ```
   gcloud storage cp gs://<bucket>/<object>#<generation> gs://<bucket>/<object>
   ```
3. For `sport-slot-dev-tfstate` specifically: prefer `terraform state
   pull`/inspection before overwriting — a bad state file restore can
   desync Terraform from reality. Validate with `terraform plan`
   (Coordinator-run) immediately after any state object restore.

## 6. Layer 5 — Container images

Artifact Registry images (`sport-slot-repo`) are rebuildable from git;
no image backup/replication is maintained (single-region, 99% SLO —
region availability is the only protection).

### Rebuild path

1. Checkout the commit corresponding to the last known-good deployed
   revision (`git log`, or the Cloud Run revision's image tag/digest).
2. Trigger a rebuild:
   - **Preferred:** re-run the GitHub Actions workflow for that commit
     (Actions → the CI/CD workflow → "Re-run all jobs", or push a
     no-op commit if re-run isn't available for an old commit).
   - **Manual fallback:** build and push directly:
     ```
     gcloud builds submit --tag asia-south1-docker.pkg.dev/sport-slot-dev/sport-slot-repo/<image>:<tag>
     ```
3. Deploy the rebuilt image to Cloud Run (CI's normal deploy path, or
   `gcloud run deploy` manually if CI is unavailable).

## 7. Layer 6 — Firebase Auth identities

Firestore backups do **not** include Firebase Auth accounts (separate
store). Recovery is export/import-based, with a manual cadence until
automated (see AUTH-EXPORT-AUTO in backlog).

### Export (weekly manual cadence)

```
firebase auth:export auth-export-<date>.json --format=json --project=sport-slot-dev
```

Also record the password hash parameters from the Firebase Console
(Authentication → Users → the hash config shown for password-hash
export) — these are required to re-import password hashes correctly
and are **not** included in the export file itself.

### Import (restore)

```
firebase auth:import auth-export-<date>.json --hash-algo=<algo> \
  --hash-key=<base64-key> [other hash params] --project=<target-project>
```

**Required:** both the export bundle and the password hash parameters
MUST be stored off-project (a project-loss disaster takes the source
project's own storage with it).

> **TODO-Coordinator:** choose the secure off-project storage location
> for the weekly export bundle + hash parameters (options to evaluate:
> a separate GCP project's GCS bucket with CMEK, or an equivalent
> access-controlled store outside this project's blast radius).

**Accepted residual risk:** identities created after the most recent
export are lost under the project-loss class; affected users
re-register.

### First-time admin bootstrap (no export to restore)

A brand-new environment (first-ever deploy of a project, or a rebuild
where no `firebase auth:export` exists yet — e.g. immediately after
Layer 3's rebuild procedure, before any weekly export has been taken)
has no identities to import. There is no platform admin to sign in as
until one is created directly.

`backend/scripts/seed_platform_admin.py` creates that first platform
admin: it is idempotent (safe to re-run — resets the password if the
address already exists), sets the four custom claims
(`role=platform_admin`, `tenant_id=null`, `tenant_slug=null`,
`household_id=null`) that `auth/dependency.py` checks, and writes the
corresponding `platform_admins` profile doc. This is the same script
used to seed the original dev environment — not a new bootstrap path.

- **When to run it:** after the app is serving (Layer 3 rebuild
  complete, backend reachable) and before the first admin login.
- **Command** (`--project` is required — no ambient/gcloud-context
  fallback, to prevent seeding the wrong environment):

  ```
  uv run python backend/scripts/seed_platform_admin.py --project <target-project-id>
  ```

- **Capture the temp password immediately.** It is generated and
  printed to stdout **once**; it is not stored or recoverable after
  the fact. Copy it to the off-project secret store used for DR
  credentials before closing the terminal.
- **Sign in fresh.** The custom claims set by this script only appear
  in a Firebase ID token issued *after* the script runs. If the admin
  has any existing session (e.g. re-running this script against an
  already-seeded environment), they must sign out and sign in again —
  refreshing an existing token is not enough to pick up the claims.

## 8. DNS (Namecheap)

### Record inventory

> **TODO-Coordinator:** fill in current values from the Namecheap
> dashboard.

| Record | Type | Target | Current TTL |
|---|---|---|---|
| Wildcard (`*.<domain>`) | A | Load Balancer static IP: TODO-Coordinator | TODO-Coordinator |
| Certificate Manager DNS authorization | CNAME | TODO-Coordinator | TODO-Coordinator |

### Rebuild procedure

1. Provision a new global static IP for the Load Balancer (Terraform-
   managed — see `terraform/load_balancer_network.tf`).
2. Update the wildcard A record in Namecheap to point at the new
   static IP.
3. If certificates need re-authorization (new Certificate Manager
   resource), create the new DNS authorization CNAME record in
   Namecheap matching the value Certificate Manager issues.
4. Wait for DNS propagation (bounded by TTL) and certificate issuance
   before considering the rebuild complete.

**Recommendation:** lower TTLs to 300–600s ahead of any planned DR
drill or migration, so a real cutover doesn't spend hours waiting on
long-TTL propagation. Revert to a higher TTL afterward if the shorter
TTL has a query-volume cost implication worth avoiding.

## 9. Timed drill plan

**A restore runbook that hasn't been executed is not a DR plan**
(ADR-0038 "Deliverable and proof"). Executed at PR-1 closure, after
both PR-1a and PR-1b have merged and applied.

### Plan

1. **Environment:** a separate scratch GCP project (zero blast radius
   to `sport-slot-dev`).
2. **Scope:** all six layers, in dependency order:
   1. Terraform rebuild (Layer 3) — project skeleton, IAM, networking.
   2. Firestore restore (Layer 1) — PITR or backup restore into the
      scratch project (see the Layer 1 TODO on cross-project backup
      restore — this drill is exactly where that gets answered).
   3. Secrets (Layer 2) — re-issue and populate shells.
   4. GCS buckets (Layer 4) — recreate/restore as needed.
   5. Container images (Layer 5) — rebuild via CI against the scratch
      project's Artifact Registry.
   6. Firebase Auth (Layer 6) — import the most recent export.
   7. DNS (chapter 8) — point a throwaway subdomain at the scratch
      environment to validate the full path end-to-end (not the
      production domain).
3. **Measurement:** wall-clock time from "declare disaster" to "app
   serving correct traffic in the scratch project," recorded against
   the 4-hour RTO target.
4. **Output:** drill report appended to this runbook (date, duration,
   deviations from the procedures above, fixes needed before the next
   drill) and any corrective backlog items filed.

> **TODO-Coordinator:** schedule the drill date once PR-1b has merged
> and applied.
