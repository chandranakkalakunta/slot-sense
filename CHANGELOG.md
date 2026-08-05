# Changelog

All notable changes to SportSlotReservation are documented in this
file. The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### feat(finops): environment power control (ADR-0047)

Sleep/wake GCP envs to cut fixed cost (especially Memorystore Redis):
`scripts/env-power.sh` + Makefile (`env-enable` / `env-disable` / `env-hold`),
registry `infrastructure/env-power.json`, state/hold in
`gs://<project>-env-power/`, nightly GHA at 23:00 Asia/Kolkata, Terraform
IAM + bucket (`terraform/env_power.tf`). Runbook:
`docs/runbooks/env-power.md`. Residual LB cost while off is expected.

### feat(test-env): multi-tenant population seeder + warm Cloud Run

`scripts/seed_test_population.py` seeds 20 tenants (incl. marina-skies/rvrg),
random flats/members, `{slug}.resident.n@example.com` with shared password,
facilities by catalog × size, resumable state. Terraform
`cloud_run_min_instances` / max for test warm instance. Runbook:
`docs/runbooks/seed-test-population.md`.

### test(func): remaining S-FUNC + Playwright smoke + CI workflow

Agent propose/confirm, invoice admin (latest/export/regenerate), health
latency sample, Playwright sign-in E2E (`tests/e2e`), GitHub
`functional.yml` workflow_dispatch, R2 regression checklist doc.

### test(func): expand S-FUNC to full critical journey pack

Platform catalog CRUD, tenant provision + 6-digit force-password,
book→list→cancel, concurrency (N→1×201), daily overview, invoices/mine,
voice smoke. Interactive runner prompts for platform/tenant admin and
mutation skips. Playwright UI still backlog.

### test(func): live S-FUNC suite for deployed env wiring (ADR-0045)

Add `tests/functional/` + `scripts/run_functional.sh` — pytest against a
real HTTPS env (Firebase ID token, tenant host, SPA scrape). Catches
cross-env SPA config, Redis LOCK_UNAVAILABLE, Vertex disabled, horizon,
and host isolation. Manual Playwright journeys remain for full UI pack;
regression extraction is a follow-up.

### fix(frontend): inject VITE_BASE_DOMAIN on bootstrap + register test-03

ADR-0046 redirects use `VITE_BASE_DOMAIN`. Bootstrap Phase 7 only injected
Firebase VITE_* so the test SPA fell back to prod apex and skipped host↔claim
redirects on `*.slotsense-test`. Bootstrap now bakes + fail-closes on base
domain; CI registry points at `slot-sense-test-03`.

### feat(ci): same-SHA backend image promote (copy, no rebuild)

- Registry `promote_from`: test copies API image from `sport-slot-dev` AR;
  standing dev still **builds**. Frontend always rebuilt per env.
- `scripts/promote_image.sh` — cross-project AR copy; fail closed if source missing.
- Terraform `artifact_registry_reader_members` so downstream WIF can read source AR.
- Design: `docs/design/same-sha-image-promote.md`.

### feat(dns): multi-env base domains (ADR-0046) — test first

- **ADR-0046:** per-env bases (`slotsense-dev` / `slotsense-test` / `slotsense`)
  with one wildcard A + Certificate Manager cert per project; retires Pattern B
  (`admin-test` / `rvrg-test` under shared `*.slotsense`).
- **Terraform:** cert DNS auth, certificate domains, URL map hosts, and edge
  uptime probe host derived from `var.base_domain`.
- **Frontend:** `VITE_BASE_DOMAIN` drives host→slug and claim-mismatch redirects
  so test never bounces to the prod/dev apex.
- **CI:** deploy registry test row → `slotsense-test.chandraailabs.com`;
  frontend build injects and fail-closes on `VITE_BASE_DOMAIN`.
- **Bootstrap:** defaults base domain by environment; admin = `admin.<base>`;
  manifest DNS documents wildcard A (no per-tenant records).
- **Runbook:** `docs/runbooks/multi-env-dns-cutover.md` (Namecheap + cert cutover).

### feat(ci): progressive multi-env deploy (option A) + S-SMOKE health

- **`deploy.yml`:** `push` main → `sport-slot-dev`; `workflow_dispatch`
  with `environment` + optional `git_sha` for promote (test supported).
- **`.github/deploy-environments.json`:** per-env project, WIF project
  number, AR repo, admin host, Firebase config path, health URL.
- **Firebase web configs** committed under
  `infrastructure/firebase-web-configs/` for CI frontend builds.
- Frontend build injects `VITE_FIREBASE_*` and fails if wrong `projectId`.
- Post-deploy **smoke** job curls env health URL with retries.
- GitHub `environment:` maps to `dev` / `test` for future protection rules.

### docs(adr): normalize ADR filenames 0038–0043 to NNNN-slug.md

Phase 17 ADRs had been saved as `ADR-0038-….md` … `ADR-0043-….md` while
0001–0037 and 0044–0045 used `NNNN-slug.md`. Renamed the six files and
updated all markdown links; documented the convention in
`docs/adr/README.md` and `template.md`.

### docs(adr): ADR-0045 test strategy and environment promotion

Accepted ADR defining layered suites (S-STATIC, S-REG-UNIT, S-SMOKE,
S-FUNC, S-PERF, …), same-SHA progressive promote CI→dev→test→prod,
prod human approval, and ordered implementation backlog (progressive
CI and smoke first). Links `docs/testing/TEST-STRATEGY.md` as the
living runbook.

### docs(testing): test strategy, suite model, and env promotion

Added `docs/testing/TEST-STRATEGY.md` — inventory of existing suites, target
smoke/regression/functional/performance packs, how to run them on test, and
dev→test→prod promotion principles (same SHA, gates, manual promote until
multi-env CI exists).

### fix(arch): move platform-admin profile Firestore access to repository layer

`api/v1/users.py` imported `google.cloud.firestore` (DELETE_FIELD), breaking
`test_handlers_do_not_import_firestore`. Profile get/clear now via
`PlatformAdminRepository` / `UserProfileRepository`.

### feat(auth)+feat(admin): force platform-admin password change, 6-digit initial codes, facility catalog CRUD

Closes three product gaps found on first test-01 login:

1. **Platform admin force-change** — `usePasswordGate` no longer excludes
   `platform_admin`; `PlatformRoute` redirects to `/force-password`;
   `GET/POST /users/me` reads and clears `platform_admins/{uid}`.
2. **ADR-0044** — initial credentials are 6-digit codes
   (`generate_initial_password`); user password min length 8; 24h
   `temp_password_expires_at` on provision/reset/seed; expired codes
   refuse change and disable the account (`TEMP_PASSWORD_EXPIRED`).
3. **Facility catalog admin CRUD** — `POST/PATCH/DELETE
   /admin/facility-catalog` + `/admin/facility-catalog` UI; tenants still
   pick types when creating instances.

### fix(dr): drop rvrg-* from bootstrap public host (admin host only)

Bootstrap no longer invents a demo tenant hostname (`rvrg-dev` /
`rvrg-test` / `rvrg`) as the env entry URL — that mixed tenant slug with
environment and broke multi-env mental model. Health + login host defaults
to platform admin only (`admin-dev` / `admin-test` / `admin`). Manifest DNS
section warns against a single `*.slotsense` A → one LB IP when dev/test/prod
must run together. Tenant hosts are operator-created when tenants are added.

### fix(tooling): Phase 7 tf.sh registry edit — portable awk + register test-01

`ensure_tf_sh_registry_entry` used awk `/^\s*\*)/` which does **not**
match on macOS/BSD awk (`\s` is not whitespace). After a successful
admin seed on `slot-sense-test-01`, Phase 7d failed with "could not
locate ENV_NAMES and/or *) arm". Switch to `[[:space:]]`; also commit
the `test-01` registry arm so resume can skip the edit.

### fix(tooling): Phase 2 Firebase verify — REST + retries (not flaky projects:list)

`firebase projects:addfirebase` can succeed while a subsequent
`firebase projects:list | grep` still misses the project for tens of
seconds (live on `slot-sense-test-01`, 2026-08-01). Phase 2 now verifies
via Firebase Management REST (`projects.get`, state=ACTIVE) with retries,
falling back to CLI list only as a secondary signal.

### docs(runbooks): plain-English create-environment step-by-step guide

Added `docs/runbooks/create-environment-step-by-step.md` — full start-to-finish
procedure (preflight, script, DNS, cert, first login, checklist) so any
English-speaking operator can stand up a SlotSense env without reading the
DR ADR. Linked from `provision-environment.md` and `disaster-recovery.md`.

### fix(dr): single-touch multi-env bootstrap — Firebase web app + frontend Auth wiring (PR-L)

dev-03 live drill left the SPA authenticating against `sport-slot-dev`
even though Auth/Firestore/seed were correctly isolated on
`slot-sense-dev-03`. Root cause: Phase 7 ran bare `pnpm build`, which
baked committed `frontend/.env.production` (`projectId: sport-slot-dev`)
into the new env's frontend bucket, and Phase 2 never created a
Firebase WEB app (0 web apps on dev-03). Seed password unused
(`lastLogin=null`); old dev password "worked" because login never hit
dev-03 Auth.

- **`scripts/drill-bootstrap.sh`**: Phase 2 creates/reuses a Firebase
  WEB app via Management REST (gcloud ADC) and caches public SDK config
  to `.drill-firebase-web-config-<project>.json`. Phase 7 builds the
  frontend with shell `VITE_FIREBASE_*` for the **target** project,
  fails hard if `dist` does not embed that `projectId`, deploys Hosting
  + GCS, seeds admin, and auto-registers the env in `scripts/tf.sh`.
  Phase 8 verifies hosted JS `projectId` and LB `/health` via Host
  header. Phase 0 derives Pattern B hosts (`rvrg-dev` /
  `admin-dev.*`, etc.). Phase 9 manifest lists login URL + remaining
  manual DNS only.
- **`scripts/deploy_cloud_run.sh`**: no silent `sport-slot-dev` default
  (require `SLOTSENSE_PROJECT` / `REGION` / `ARTIFACT_REPO`); pins
  `VERTEX_PROJECT`, invoice bucket, welcome/reset URLs to the deploy
  target so config.py sport-slot-dev defaults cannot leak.
- **`Makefile` `deploy-dev`**: supplies legacy sport-slot-dev defaults
  so CI/local `make deploy-dev` still works.
- **Docs**: `provision-environment.md` automatic-vs-manual table;
  `.gitignore` for Firebase web config cache.

### chore(infra): register dev-03 in tf.sh, prune dev-01, true-up DRILL-PASS-2 backlog

Registered `slot-sense-dev-03` in `scripts/tf.sh` and pruned the deleted
`dev-01` environment; trued-up `docs/backlog.md`'s `DRILL-PASS-2` entry
to the 2026-07-25 descope (no data/auth migration; DNS/cert cutover
remains).

- **`scripts/tf.sh`**: `ENV_NAMES` and `env_lookup()`'s `dev-01` case arm
  replaced with `dev-03` (`slot-sense-dev-03` project/bucket/varfile).
  `dev-01`'s project is deleted (30-day `DELETE_REQUESTED` window) and
  its local `.tfvars` is being removed, so the arm is fully pruned, not
  just relabeled. The `dev`/`sport-slot-dev` arm is retained — retirement
  is a separate, Coordinator-paced item (`SPORT-SLOT-DEV-RETIRE`).
- **`docs/backlog.md`**: `DRILL-PASS-2` flipped from `OPEN` to
  `IN PROGRESS`, reflecting the dev-03 drill's actual result (~21 min
  rebuild, well inside the 4h RTO) and the 2026-07-25 Coordinator
  decision to descope Firestore/Auth export-import (no migration needed
  — dev-03 is populated fresh). New entries: `DNS-PATTERN-B` (locked —
  `rvrg-dev`/`rvrg-test`/`rvrg` labels under one wildcard cert),
  `SPORT-SLOT-DEV-RETIRE` (open, Coordinator pace), and
  `TF-SH-REGISTRY-DEV-03` (done, this PR).

### fix(ci): pass SLOTSENSE_* env vars in deploy.yml build-push step (PR-K)

PR-I removed `scripts/build_push.sh`'s silent
`SLOTSENSE_PROJECT:-sport-slot-dev` default — correctly, to
prevent accidental production deploys. But `.github/workflows/
deploy.yml`'s `Build + push backend, deploy Cloud Run` step
did not set that env var explicitly, so every push to main
after PR-I hit the new hard-fail at build_push.sh line 6.

PR-K adds `SLOTSENSE_PROJECT`, `SLOTSENSE_REGION`, and
`SLOTSENSE_ARTIFACT_REPO` to the step's env block, hardcoded
to sport-slot-dev — the value the removed default was
providing. Full per-env CI parameterization (the ~5 other
sport-slot-dev hardcodes in deploy.yml — SA emails, bucket
names, WIF provider) remains tracked as a separate backlog
item and is not touched here.

Also opens `CI-DEPLOY-CLOUD-RUN-DEFAULTS-ASYMMETRY` — same
hazard PR-I closed in build_push.sh still lives in
deploy_cloud_run.sh's `SLOTSENSE_PROJECT:-sport-slot-dev`
default; deferred to the larger CI parameterization job.

### fix(tooling)+fix(tf): drill-bootstrap.sh live-drill hardening (PR-J)

The dev-03 (2026-07-25) first live drill surfaced four gaps invisible
to dry-run. Root cause common thread: subshells and external commands
that don't cooperate with `set -euo pipefail` (silent Phase 8 exit;
brittle stdout pattern match on external CLI output; Firebase token
expiry mid-run that no preflight caught). Plus one non-drill config gap
that would have bitten prod (budget hardcoded to dev-scale).

- **Phase 8 must always write the Phase 9 manifest.** Verify failures
  record into the manifest and stop the script's overall exit code, but
  do not skip the manifest write. `gcloud logging read` and
  `terraform plan -detailed-exitcode` now capture their exit status
  separately from the pipeline/command result and treat a transient
  failure (auth expiry, logging API not yet queryable, network hiccup)
  as WARN-and-continue rather than fatal; the phase8 fail decision
  moved to `main()`, running strictly after `phase9`. Fixes the silent
  exit that left dev-03 without a `bootstrap-output-*.md` file.
- **Phase 0 Firebase preflight.** `firebase projects:list` at preflight
  time, alongside the existing ADC check; hard-fails with a
  `firebase login --reauth` instruction if not valid. Firebase CLI
  tokens expire faster (~1h idle) than gcloud ADC and were not
  previously checked — this killed Phase 7's `firebase deploy`
  mid-run on dev-03.
- **Phase 2 addfirebase verified via projects:list.** Replaced the
  brittle stdout pattern match (`already|success|Firebase resources`)
  — unstable across firebase-tools versions, and observed to
  false-warn on dev-03 despite success — with a stable, API-shaped
  ground-truth check.
- **`terraform/cost.tf` budget parameterized by `var.environment`.**
  New `local.budget_amounts_inr` / `local.budget_display_names` maps;
  dev/test at ₹5,000, prod placeholders (also ₹5,000) with a
  `TODO(prod)` comment for the Coordinator to set real prod ceilings
  before first prod apply. Resource address unchanged (no
  destroy/recreate).
- **`docs/runbooks/provision-environment.md`**: new "Authentication
  Error / Your credentials are no longer valid" (Firebase CLI)
  subsection under Known failures.
- **`docs/backlog.md`**: `PHASE-8-SILENT-EXIT`,
  `PHASE-0-FIREBASE-PREFLIGHT`, `PHASE-2-STDOUT-MATCH-BRITTLE`, and
  `BUDGET-CEILING-PER-ENV` all marked RESOLVED by PR-J.

### fix(tooling)+feat(docs): drill-bootstrap.sh Phase 3 closure + operator card (PR-I)

The dev-02 drill run surfaced five gaps in PR-G's single-touch path —
all root-caused to memory-based assumptions about IAM closure that
reading terraform/iam.tf + scripts/setup_build_infra.sh directly would
have caught. PR-I closes them and adds the one-page operator card for
future provisioning.

- **terraform/iam.tf**: authored
  google_storage_bucket_iam_member.cloud_build_staging_object_admin —
  grants sa-cloud-build roles/storage.objectAdmin on the staging
  bucket. Previously held only by scripts/setup_build_infra.sh
  (imperative, hardcoded, never codified). Without it,
  gcloud builds submit --service-account=sa-cloud-build in Phase 4
  gets a 403 on storage.objects.get.
- **scripts/drill-bootstrap.sh Phase 3**: target list expanded from 7
  to 12 (adds google_service_account.cloud_build plus its four IAM
  bindings including the new one). Split into 3a (APIs only) + 60s
  propagation wait + 3b (resources) to prevent the Google API
  propagation race that hit Secret Manager on dev-02.
- **scripts/drill-bootstrap.sh Phase 0**: added ADC readiness
  preflight (gcloud auth application-default print-access-token) with
  hard-fail and clear "run gcloud auth application-default login"
  instruction. Replaces the misleading warn-and-continue behaviour
  that hid an ADC failure right before terraform init died on it.
- **scripts/build_push.sh**: removed sport-slot-dev fallback for
  SLOTSENSE_PROJECT. Now hard-fails if unset. Prior behaviour allowed
  accidental invocation against production.
- **scripts/setup_build_infra.sh**: deleted. Sole unique action (the
  bucket IAM) codified in iam.tf. Other actions already codified.
- **docs/runbooks/provision-environment.md**: new one-page operator
  card. Preflight commands with expected outputs; the two commands to
  run; four Known failure scenarios with one-line fixes; post-run
  manual tail (manifest, DNS records for Pattern B labels, cert wait,
  tf.sh registry). Aimed at operator with no SlotSense context.
- **docs/runbooks/disaster-recovery.md**: setup_build_infra.sh
  retirement noted.
- **docs/backlog.md**: added 6 RESOLVED-by-PR-I entries, 1
  RESOLVED-by-v3.9 entry, 1 new OPEN item
  (TERRAFORM-API-PROPAGATION-TIME-SLEEP — the script split is a
  workaround; the Terraform-native fix affects production applies and
  is deferred).
- **Protocol** (out-of-band, org-level document): v3.9 adopted
  alongside PR-I — new §0.1 item 13 and §4.14 (Read Before You
  Recommend), §5.35 failure pattern.

### fix(tooling): drill-bootstrap.sh hardening (PR-H)

Strategist's post-merge diff review of PR-G #164 surfaced five gaps to
close before the script's first live run against a fresh project.

- **Phase 7c (admin seed)**: `seed_platform_admin.py`'s stdout — which
  includes the temp admin password verbatim — was being piped through
  `tee -a "${CMDLOG_FILE}"`, writing the password into the persistent
  command log. Now captured to an ephemeral, `chmod 600` temp file only;
  `CMDLOG_FILE` never sees it. `ADMIN_EMAIL_CAPTURED`/`ADMIN_TEMP_PASSWORD`
  parsing unchanged.
- **Phase 5**: added a comment explaining why "exactly 1 ENABLED
  version" is a strict, fail-loud check rather than "at least 1" — an
  automatic double-write of secret versions on re-run would be worse
  than stopping and letting the operator decide (disable the prior
  version and re-run if a second version is genuinely intended).
- **Header block**: documented that `sport-slot-redis`, `sport-slot-api`,
  and `slot-sense-repo` are intentionally hardcoded — the sport-slot ->
  slot-sense migration renames `PROJECT_ID`, not the terraform-owned
  resource names inside any given project.
- **Phase 9 output manifest**: added a caveat above the per-phase
  elapsed-times table — Phase 6 timings include operator review time on
  the interactive `terraform apply` unless run with `--yes`; use
  `--yes` for a comparable RTO measurement across runs.
- **`docs/backlog.md`**: added `CLOUD-RUN-WORKER-URL-COMPUTED` (open),
  naming the root cause behind PR-G's Phase 6b corrective-deploy
  workaround — `terraform/cloud_run.tf`'s `SPORTSLOT_WORKER_BASE_URL`
  is hardcoded to sport-slot-dev's live URL rather than computed.

No `.tf` files touched.

### feat(tooling): drill-bootstrap.sh — single-command environment build (PR-G)

DR drill Pass 1 proved the rebuild sequence manually; PR-B/C/D/E/F
codified every config gap it found. This closes `DRILL-BOOTSTRAP-SCRIPT`:
the proven sequence is now one command instead of a runbook a human has
to execute by hand.

- **`scripts/drill-bootstrap.sh`** (new): implements
  `docs/runbooks/disaster-recovery.md` §4.1 end to end — project
  create/billing link (with retry), 3 bootstrap APIs, tfstate bucket,
  generated per-environment `terraform/<project_id>.tfvars`,
  `firebase projects:addfirebase`, the bootstrap-group `terraform apply`
  (APIs + Artifact Registry + Cloud Build IAM + staging bucket + Redis +
  secret shells), image build (`build_push.sh`), secret value population
  (redis-auth, resend-api-key), the main apply, Firestore rules/indexes,
  frontend build + Hosting + GCS sync, platform-admin seeding, and a
  verification pass (revision Ready/100% traffic, zero WARNING+ logs
  since deploy, `terraform plan` clean). Writes a gitignored
  `bootstrap-output-<project_id>-<timestamp>.md` manifest with the LB
  IP, DNS records, Cloud Run URL, temp admin password, and the
  `scripts/tf.sh` registry entry to add. `--dry-run` validates inputs
  and prints the plan with zero gcloud/terraform/firebase calls;
  `--start-phase N` resumes a failed run using a gitignored per-project
  state cache so flags don't need to be repeated.
- **Verification finding (not previously spec'd):**
  `terraform/cloud_run.tf`'s `SPORTSLOT_WORKER_BASE_URL` env var is
  hardcoded to the live sport-slot-dev Cloud Run URL, not derived from
  any variable — a new environment's first Terraform-created revision
  would otherwise self-reference the wrong (existing dev) service. The
  script adds a corrective step right after the main apply, reusing the
  existing `scripts/deploy_cloud_run.sh` (the same script CI already
  runs after every Terraform apply in production) so the URL
  self-corrects once the service exists — no `.tf` changes.
- **`.gitignore`**: added `bootstrap-output-*.md`,
  `.drill-bootstrap-state-*.env`, `.drill-bootstrap-*.cmdlog`,
  `.drill-bootstrap-*.timing`.
- **`docs/runbooks/disaster-recovery.md`**: §4.1 now points at the
  script as the primary rebuild path; the manual procedure remains the
  documented fallback and the spec the script implements.
- **`docs/backlog.md`**: `DRILL-BOOTSTRAP-SCRIPT` marked resolved.

### feat(tf): codify Firebase auth provider; make SMS alert channel conditional (PR-F)

Environment Provisioning Spec GAP 2.2 and 2.3 — two manual console
steps that blocked an unattended environment build.

- **`terraform/auth.tf`** (new): `google_identity_platform_config.auth`
  codifies enabling the Email/Password Firebase Auth sign-in provider,
  which `firebase projects:addfirebase` does not turn on and
  `seed_platform_admin.py` requires (`CONFIGURATION_NOT_FOUND`
  otherwise; DR drill Pass 1 discovery). Verified before authoring
  (not assumed): the resource's REST calls target
  `identitytoolkit.googleapis.com/v2` — already enabled, already
  backing standard Firebase Auth — and `identityplatform.googleapis.com`
  does not appear anywhere in the pinned `hashicorp/google` 6.50.0
  provider binary, so no GCIP billing-tier upgrade risk. Live check
  against sport-slot-dev confirms `subtype: FIREBASE_AUTH`. No new API
  enablement needed (`identitytoolkit.googleapis.com` already in
  `apis.tf`). sport-slot-dev already has a live Config object pre-dating
  this resource — Coordinator must run
  `terraform import google_identity_platform_config.auth sport-slot-dev`
  before its next plan/apply; new environments need no import.
- **`terraform/observability.tf`**: the `"Coordinator SMS"` notification
  channel data source (an unconditional lookup that failed the
  **entire plan** on any environment without the console-created
  channel — DR drill Pass 1 finding #9) is now gated behind
  `var.enable_sms_alerts` (`terraform/variables.tf`, default `false`).
  New environments build email-only by default; SMS attaches once the
  channel exists and is phone-verified, by setting the var `true`.
  Legacy sport-slot-dev's gitignored tfvars must set
  `enable_sms_alerts = true` to keep its existing SMS channel attached.
- **`terraform/terraform.tfvars.example`**: documented
  `enable_sms_alerts` (commented, default false).
- **`docs/runbooks/disaster-recovery.md`**: §4.1 steps 4–5 updated —
  auth provider is now Terraform-managed (import caveat for existing
  environments noted); SMS channel creation is optional/deferred.
  §4.2 inventory table updated.
- **`docs/backlog.md`**: AUTH-PROVIDER-CODIFY (new) and
  SMS-CHANNEL-DECISION marked resolved.

### fix(admin): explicit --project targeting + correct default email for seed_platform_admin; document first-admin bootstrap in DR Layer 6 (PR-E)

`backend/scripts/seed_platform_admin.py` already existed and correctly
created the first platform admin, but had no way to target a specific
GCP project — it resolved the project from ambient ADC/gcloud config,
so running it against the wrong context could silently seed an admin
into the wrong environment. DR runbook Layer 6 also never referenced
the script, so a rebuilt environment had no documented path to first
login (DR drill Pass 1 finding #3, corrected in this PR — the tooling
existed, targeting and docs were the actual gaps).

- **`backend/scripts/seed_platform_admin.py`**: added a required
  `--project` argument (no default, no ambient fallback; exits
  non-zero if absent), passed explicitly to both
  `firebase_admin.initialize_app(options={"projectId": project})` and
  `firestore.Client(project=project)`. Default admin address changed
  from `admin@sportbook.chandraailabs.com` to
  `admin@chandraailabs.com` (one address across all environments;
  `PLATFORM_ADMIN_EMAIL` override unchanged). `must_change_password`
  now written as `True` — confirmed inert for `platform_admin` (the
  frontend password gate explicitly excludes that role; no backend
  code reads the field), so this documents intent without changing
  behavior.
- **`docs/runbooks/disaster-recovery.md`**: added a "First-time admin
  bootstrap (no export to restore)" subsection under Layer 6, covering
  when to run the script, the `--project` command, the one-time-only
  temp password, and the sign-in-fresh caveat for claim propagation.
- **`docs/runbooks/DRILL-pass1-report.md`**: corrected finding #3 —
  it previously stated bootstrap tooling was "unsolved"; the script
  existed, targeting and runbook documentation were the actual gaps.
- **`docs/backlog.md`**: PLATFORM-ADMIN-BOOTSTRAP marked resolved.

### fix(deploy): parameterize deploy pipeline for multi-env; Terraform owns scaling (ADR-0041 D15); cloudbuild staging bucket in TF (PR-C)

DR drill Pass 1 (`docs/runbooks/DRILL-pass1-report.md`) rebuilt
`slot-sense-dev-01` successfully but surfaced that the deploy pipeline
was still single-environment and one script silently reverted an ADR
decision on every deploy. PR-C closes those gaps.

- **`scripts/deploy_cloud_run.sh`**: removed `--min-instances=0
  --max-instances=2` from the `gcloud run deploy` call. Terraform sets
  `max_instance_count = 10` (ADR-0041 D15); this script's hardcoded `2`
  was silently overwriting it on **every** deploy, so maxScale 10 had
  never actually held in production (D7 model: CI owns image + env,
  Terraform owns template config). `PROJECT`, `REGION`,
  `ARTIFACT_REPO`, `SPORTSLOT_BASE_DOMAIN`, and `SPORTSLOT_ADMIN_HOST`
  now read from `SLOTSENSE_*` env vars, defaulting to today's
  `sport-slot-dev` values — no behavior change for existing CI.
- **`scripts/build_push.sh`**: same parameterization for `PROJECT`,
  `REGION`, `ARTIFACT_REPO` (`BUCKET` already derived from `PROJECT`).
- **`terraform/base_infra.tf`**: added
  `google_storage_bucket.cloudbuild_staging` (`<project_id>-cloudbuild`,
  30-day delete lifecycle rule) — this bucket is required by
  `build_push.sh --gcs-source-staging-dir` but nothing created it in a
  fresh project, causing `wif_iam.tf`'s
  `ci_cloudbuild_staging_object_admin` IAM binding to 404 (DR drill
  Pass 1, finding #8). One-time `terraform import
  google_storage_bucket.cloudbuild_staging sport-slot-dev-cloudbuild`
  needed in `sport-slot-dev` before its next clean plan.
- **`terraform/wif_iam.tf`**: added `depends_on =
  [google_storage_bucket.cloudbuild_staging]` on
  `ci_cloudbuild_staging_object_admin` so a fresh-project apply
  sequences correctly.
- **`docs/runbooks/disaster-recovery.md`** §4.1: reordered the rebuild
  procedure to the drill-proven sequence — bootstrap-group apply
  (APIs + Artifact Registry + Cloud Build SA IAM + cloudbuild staging
  bucket) → image build → **secret population** → main apply → verify.
  Added a hard warning that secret values must exist before the Cloud
  Run apply (finding #7: creating it first leaves the service tainted
  with `SECRETS_ACCESS_CHECK_FAILED`, and `prevent_destroy` then blocks
  self-healing, requiring manual `terraform untaint` + a forced
  revision), and a note that the org-policy exception needs ~1-2 min
  propagation before the `allUsers` frontend binding succeeds (finding
  #10). §4.2 corrected: the default Compute SA is **not** unused — it
  is Cloud Build's default identity in new projects.
- **Backlog**: added `PLATFORM-ADMIN-BOOTSTRAP`, `SMS-CHANNEL-DECISION`,
  `DRILL-BOOTSTRAP-SCRIPT`, `DRILL-PASS-2` (all OPEN, findings #3/#9
  and the drill's follow-on work). Ref: DR drill Pass 1.

### docs: Phase 17 close-out — retrospective, ADR-0042 email-only amendment, backlog closures

Phase 17 (Production Readiness) is **build-complete**: all ten
2026-07-13 baseline audit findings resolved across PR-1a → PR-5c
(#141–#155). This is a docs-only close-out — no infra, no Terraform,
no CI changes.

- **`docs/retrospectives/phase-17-closeout.md`** (placed): audit
  findings scoreboard (10/10 resolved), sub-phase ledger (#141–#155),
  API-shape lessons earned this phase (billing budget 400s, Cloud Run
  probe budget math, `run.developer` vs `run.admin`, dashboard
  perma-diff canonical form, and more), process lessons (merge ≠
  applied, WIF/Armor "look before you leap" gates), and open threads
  carried into Phase 18 (`VOICE-INPUT-VALIDATION`, the timed DR
  drill/TEST-env, `CI-AUDIT-RATCHET`).
- **`docs/adr/0042-cost-guardrails.md`** amended under D18: the
  Budget API rejected `monitoring_notification_channels` combined
  with default IAM recipients and rejected the SMS channel
  specifically (opaque 400s, isolated by removing the notification
  block first). Final wiring is **Admin Email only**
  (`disable_default_iam_recipients = true`) — supersedes the original
  "backup emails stay" note, not achievable alongside a monitoring
  channel. SMS remains on the outage path (PR-2); cost alerts are
  slower-urgency and the forecasted-breach threshold already gives
  days of warning.
- **Backlog**: `PR-5-SECURITY`, `PR-2-OBSERVABILITY`,
  `PR-3-AVAILABILITY`, `PR-4-COST` all flipped to `✓ DONE` with their
  merged PR numbers (`#144–#147`, `#148–#150`, `#151–#152`,
  `#153–#155` respectively — confirmed against `main`'s merge log,
  not assumed). `ARMOR-ENFORCE-GATE` closed out with its PR number.
  Confirmed `VOICE-INPUT-VALIDATION`, `VOICE-HARDEN-01`/`02`,
  `SEC-01`, `SLO-LOAD-TEST`, `CI-AUDIT-RATCHET`, `TEST-PROJECT-BUDGET`,
  `AUTH-EXPORT-AUTO`, `BACKUP-ABSENCE-ALERT`, `HARDENING-RESIDUALS`
  all already present and correctly OPEN/BLOCKED/DEFERRED — none
  were missing. New top-line note: Phase 17 build-complete, drill
  pending.

### feat(security): Cloud Armor API WAF enforce with voice-path exemption (ADR-0043, option 2; finding #7)

Closes the last of the ten 2026-07-13 baseline audit findings. Builds
directly on PR-5b's preview-log review, which found (complete 14-day
window) that 100% of preview-flagged-but-accepted traffic on the API
Armor policy was legitimate `/api/v1/agent/voice` traffic — large
base64-audio payloads false-positiving on the generic OWASP CRS
SQLi/XSS body-inspection signatures. Coordinator decision: option 2.

- **`terraform/cloud_armor.tf`**: added one new rule to
  `google_compute_security_policy.api` — `priority = 900`, `action =
  "allow"`, matching `request.path.matches('/api/v1/agent/voice')` —
  at a lower priority number (= higher precedence) than the SQLi rule
  (1000) and XSS rule (2000). Cloud Armor evaluates rules in priority
  order and stops at the first match, so voice-path requests never
  reach the WAF rules. Those two rules then flip `preview = true` →
  enforcing; their match expressions, priorities, and actions are
  byte-for-byte unchanged — only the exemption is new, only the mode
  flips. Every other path now gets real SQLi/XSS enforcement.
  `frontend_edge` is untouched: confirmed (PR-5b) that
  `CLOUD_ARMOR_EDGE` structurally cannot hold `evaluatePreconfiguredWaf`
  rules, so its zero-rule pass-through was never a gap to close, only
  a constraint to document — now stated explicitly as intentional in
  the resource's own comment.
- **Accepted residual, documented not silent**: the voice path's
  SQLi/XSS defense is now field-level input validation and safe sinks
  (Firestore is non-SQL; transcribed text validated in code; frontend
  escapes agent output), not the WAF. Tracked as new backlog item
  `VOICE-INPUT-VALIDATION`, scoped to the Phase 18 launch gate — the
  durable fix for the exempt path, not attempted in this PR.
- **`docs/adr/0043-security-hardening.md`** amended in place
  (matching this project's inline-annotation convention for
  post-hoc decision outcomes, not a superseding ADR — this decision
  was already scoped as PR-5b item 1's own follow-through): the Armor
  section now records the preview-log finding, the option-2 decision,
  and the accepted-residual paragraph; Consequences updated to reflect
  finding #7 fully closing.
- `terraform fmt`/`validate` clean (`init -backend=false`,
  scratch-copy, local-only — validate does not prove Armor expression
  acceptance; the Coordinator's live apply + verification, below, is
  the real gate). Plan and apply are Coordinator-run and not yet
  executed.
- Backlog: `ARMOR-ENFORCE-GATE` → resolved (option 2, this PR); new
  `VOICE-INPUT-VALIDATION · OPEN (Phase 18)`; `PR-5-SECURITY` →
  all sub-PRs shipped.

### feat(security): WIF least-privilege — bucket-scoped storage, run.developer + minimal custom role (ADR-0043, PR-5b)

PR-5b is the risk-sensitive half of ADR-0043's security-hardening
split. Two independent concerns, kept as separate commits so either
can be reviewed/rolled back alone.

- **WIF least-privilege (shipped, `terraform/wif_iam.tf`):** the
  GitHub Actions WIF principal's project-level `roles/storage.admin`
  is replaced with two bucket-scoped `roles/storage.objectAdmin`
  grants — the only two GCS buckets CI actually touches, confirmed by
  reading `.github/workflows/deploy.yml` and `scripts/build_push.sh`
  line by line: the Cloud Build source-staging bucket
  (`sport-slot-dev-cloudbuild`, same role already proven live for
  `sa-cloud-build` on that bucket — `scripts/setup_build_infra.sh`)
  and the frontend static-asset bucket (`sport-slot-dev-frontend`,
  `google_storage_bucket.frontend`). Project-level `roles/run.admin`
  is replaced with `roles/run.developer` **plus** a new minimal
  custom role (`ciRunSetIamPolicy`, one permission:
  `run.services.setIamPolicy`) — a live check
  (`gcloud iam roles describe roles/run.developer`) confirmed
  run.developer alone lacks `setIamPolicy`, which
  `deploy_cloud_run.sh`'s `--allow-unauthenticated` flag needs (it
  grants `allUsers` `roles/run.invoker` under the hood). A blind
  run.admin → run.developer swap would have broken every CI deploy;
  this was verified, not guessed, before authoring the change. Also
  resolved a pre-existing "COORDINATOR FLAG" comment on
  `ci_act_as_cloud_build`: confirmed required, since `build_push.sh`
  explicitly passes `--service-account=sa-cloud-build@...`.
- **Cloud Armor enforce (NOT shipped — gated):** a 14-day preview-log
  review (`docs/reviews/2026-07-21-armor-preview-log-review.md`) of
  what the `slotsense-api-armor` policy's preview SQLi/XSS rules
  would have blocked found 100% of the 75 flagged-but-accepted
  requests in the window are legitimate `/api/v1/agent/voice` traffic
  from one real tenant, false-positiving on generic CRS pattern rules
  against large (20–115KB, median 54KB) voice-audio POST bodies —
  zero attack traffic in the population. Per ADR-0043's own gate
  condition, flipping preview→enforce on legitimate-traffic false
  positives is not authored blind; `terraform/cloud_armor.tf` is
  unmodified by this PR, awaiting a Coordinator tuning decision (see
  the review doc for three concrete options). `frontend_edge`'s
  zero-rule policy is also untouched — a baseline WAF ruleset there
  isn't possible at all (`CLOUD_ARMOR_EDGE` doesn't support
  `evaluatePreconfiguredWaf`, already documented in
  `terraform/cloud_armor.tf` from a prior apply-time API error).
- `terraform fmt`/`validate` clean (`init -backend=false`,
  scratch-copy, local-only). Plan and apply are Coordinator-run and
  not yet executed.
- Backlog: `WIF-LEAST-PRIV` → implemented-pending-apply; new
  `ARMOR-ENFORCE-GATE · BLOCKED (Coordinator decision)`; `PR-5a-SECURITY`
  flipped to done (merged as #153); `PR-5-SECURITY` split entry updated.

### feat(security): response security headers + CI container/dep scanning + rotation policy (ADR-0043, PR-5a)

The baseline audit and DOC-TRUTH found the security posture claimed in
docs outrunning what's enforced (findings #7, #9, #10): no security
headers despite the charter's claim, CI scanning limited to Bandit +
pip-audit + Gitleaks (no container/frontend-dependency scanning), a
legacy `containerregistry.googleapis.com` enabled with no images, and
no secret rotation policy. ADR-0043 splits the fix by blast radius;
this is PR-5a, the low-risk half (code/CI/docs only — no Terraform,
no Cloud Armor, no IAM; those are PR-5b).

- **`backend/src/sport_slot/middleware/security_headers.py`** (new):
  `SecurityHeadersMiddleware` sets `Strict-Transport-Security`
  (`max-age=31536000; includeSubDomains`), `X-Content-Type-Options:
  nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy:
  strict-origin-when-cross-origin`, and a baseline
  `Content-Security-Policy: default-src 'self'; frame-ancestors
  'none'` on every response. Wired in `main.py` as the outermost
  middleware layer (added after `RequestIdMiddleware`, so it wraps
  every response including rate-limited ones) without disturbing the
  existing `EnvelopeRateLimitMiddleware`/`RequestIdMiddleware` order.
  `default-src 'self'` is correct for this API-only backend (no
  Jinja/StaticFiles — verified via grep); known accepted tradeoff:
  FastAPI's default `/docs`/`/redoc` load CDN assets and will render
  cosmetically degraded under this CSP — dev-facing introspection
  endpoints, not a production surface, `/openapi.json` unaffected.
  Verified by `test_security_headers_on_every_response`
  (`backend/tests/test_health_and_errors.py`) and the full backend
  suite (677 passed, 93.26% coverage, `ruff`/`bandit` clean).
- **Security charter CORS claim corrected** (`docs/security/charter.md`
  v1.5 → v1.6): the claimed "CORS strict policy" doesn't exist as
  code — and doesn't need to. The load balancer's path-based routing
  (`terraform/load_balancer_routing.tf`, Phase 8b) puts frontend and
  API on the same origin per tenant subdomain, a stronger posture
  than a CORS policy would add. Not a gap; corrected to state reality
  rather than silently changing app behavior. Headers claim flipped
  Planned → Implemented in the same pass.
- **CI, `.github/workflows/pr-gates.yml`**: new `image-scan` job
  (builds the backend image locally — no push, mirrors
  `backend/cloudbuild.yaml`'s build step — then Trivy-scans it,
  CRITICAL/HIGH, warn-only) and a `pnpm audit --audit-level=high` step
  in `frontend-gates` (warn-only). Both non-blocking per the
  measured-gates principle, tied to `CI-AUDIT-RATCHET`. The frontend
  audit already surfaced 11 real findings (6 high, 1 critical, all in
  `eslint`'s `js-yaml` transitive chain) — untriaged, left for the
  ratchet pass, not patched here (out of scope for a code/CI/docs-only
  PR).
- **Legacy `containerregistry.googleapis.com` cleanup prepared, not
  run**: verified empty via two independent read-only checks
  (`gcloud container images list --repository=gcr.io/sport-slot-dev` →
  404 `NAME_UNKNOWN`; backing bucket
  `gs://artifacts.sport-slot-dev.appspot.com` → 404 not found). API
  disable is a live mutation — command prepared in the PR body for
  the Coordinator, not executed here.
- **Secret rotation policy** (`docs/runbooks/disaster-recovery.md`
  §3.1, new): cadence (event-driven on suspected compromise;
  quarterly review at this dev-stage) and a 4-step procedure
  (re-issue → add Secret Manager version → redeploy + verify → disable
  old version) for `redis-auth` and `resend-api-key`, building on
  ADR-0038's recovery inventory. Notes the non-obvious bit: both
  secrets are wired `version = "latest"`
  (`terraform/cloud_run.tf:163,172`), which Cloud Run resolves once at
  revision start — adding a new secret version alone does not reach
  already-running instances without a new revision. Policy + manual
  procedure only, no automation.
- Backlog: `PR-5-SECURITY` marked split (ADR-0043) into `PR-5a-SECURITY`
  (implemented, pending merge — this PR) and PR-5b (`WIF-LEAST-PRIV`,
  still open); `SEC-HEADERS` → done-pending-merge;
  `CONTAINERREGISTRY-CLEANUP` → pending Coordinator disable;
  `CI-AUDIT-RATCHET` extended to cover the two new scanners.
- `docs/adr/README.md`: added the ADR-0041, ADR-0042, and ADR-0043
  rows to the Phase 17 table — ADR-0041/0042 had been missing since
  their respective PRs (flagged as an adjacent gap in PR-4), backfilled
  here alongside ADR-0043's own row.

### feat(cost): billing budget + graduated threshold alerts to ops channels (ADR-0042, PR-4)

The 2026-07-13 baseline audit found zero cost guardrails (finding #5):
no budget existed, `billingbudgets.googleapis.com` had never been
enabled, and the ADR-0005 ₹5K/mo dev ceiling was enforced by nothing
but attention. ADR-0042 closes this with one Terraform-managed,
alert-only budget.

- **`terraform/cost.tf`** (new): `google_project_service` enables
  `billingbudgets.googleapis.com` for the first time.
  `google_billing_budget.slotsense_dev_ceiling` — billing-account-scoped
  resource, filtered by project to `sport-slot-dev` only (ADR-0042
  D19), amount ₹5,000/month (verified INR, the billing account's
  currency). Five graduated `threshold_rules`: 50/80/100/120% current
  spend + 100% forecasted spend — the forecasted rule is the earliest
  actionable warning of a runaway, ahead of an invoice surprise.
  Notifications reuse the existing ADR-0040 channels
  (`local.observability_channels` — Email + SMS) via
  `all_updates_rule`; billing-admin default recipients stay enabled as
  backup (`disable_default_iam_recipients = false`).
- **Alert-only is a decision, not an omission (D18):** automated
  responses (billing disable, service caps) are explicitly rejected —
  billing-disable would destroy the project's serving ability as
  collateral, and every automated actuator is a new outage mode. The
  human is the actuator.
- **`terraform/variables.tf`**: pre-existing `billing_account_id`
  variable (default already matched the live account) annotated with
  the Step 1 discovery command that verified it — not a secret, it IS
  config.
- **API-shape lesson applied proactively**: `budget_filter.calendar_period`
  and `credit_types_treatment` are set explicitly rather than left to
  implicit API defaults, following the same defaulted-but-omitted-field
  lesson PR-3's dashboard perma-diff fix (#150) just demonstrated.
- New "Cost alerts" section in `docs/runbooks/observability.md`:
  threshold table, alert-only rationale, and what to check first when
  a cost alert fires (the "SlotSense Ops" dashboard's voice/agent
  turn-volume widgets — voice is the highest per-unit-cost surface).
- `terraform fmt`/`validate` clean (`init -backend=false`, local-only,
  scratch-copy to avoid touching the live GCS backend). Plan and apply
  are Coordinator-run and not yet executed.
- Backlog: `PR-4-COST` → implemented-pending-apply; new
  `TEST-PROJECT-BUDGET · OPEN (Phase 18)` — an equivalent budget for
  `slot-sense-test` once that project exists.

### feat(availability): maxScale 10, health probes, SLO definition, ops dashboard (ADR-0041, PR-3)

The 2026-07-13 baseline audit found thin Cloud Run headroom
(`maxScale=2`, shallow TCP startup probe, no liveness probe), an
unformalized/unmeasured 99% availability SLO, and Redis named a hard
single point of failure. ADR-0041 closes the first two and accepts the
third as a documented, triggered residual.

- **`terraform/cloud_run.tf`**: `maxScale` 2 → 10 (cap, not floor;
  `minScale` stays 0). Startup probe TCP → HTTP GET `/health`.
  Liveness probe added, HTTP GET `/health` — pure-liveness semantics
  is exactly what a liveness probe needs (a dependency-checking
  endpoint would wrongly restart the container on a Redis/Firestore
  blip). This mints the first Terraform-driven Cloud Run revision
  since PR-1b adoption; live image/env remain untouched
  (`ignore_changes`, D7 model).
- **`terraform/dashboard.tf`** (new): `google_monitoring_dashboard`
  "SlotSense Ops" — voice turns/day, agent text turns/day, 5xx error
  ratio, p95 latency, edge uptime (check passed), Cloud Run instance
  count. 5xx ratio widget uses the native `timeSeriesFilterRatio`
  numerator/denominator construct (not MQL) to keep every widget in
  plain-filter form, avoiding the plan/validate-doesn't-validate-MQL
  gap PR-2 hit at apply.
- **SLO formalized at doc level (ADR-0041 D14)**: 99% monthly
  availability = edge uptime ≥99% AND 5xx ratio under the ADR-0040
  threshold, ~7.3h/month error budget. Deliberately no Monitoring SLO
  / burn-rate API resources yet — gated behind backlog
  `SLO-LOAD-TEST`. New section in `docs/runbooks/observability.md`.
- **Redis SPOF accepted as documented residual (ADR-0041 D16)**:
  BASIC tier affirmed over STANDARD_HA at this stage (cost vs. an SLO
  that already tolerates the risk, dev-stage, no paying tenants), with
  three explicit revisit triggers. Cross-referenced from
  `docs/runbooks/disaster-recovery.md`'s Redis non-goal section.
  Backlog: new `REDIS-HA-TRIGGERS · DEFERRED` entry.
- `terraform fmt`/`validate` clean (`init -backend=false`, local-only).
  Plan and apply are Coordinator-run and not yet executed.

### feat(obs): observability & alerting baseline — channels, uptime checks, alert policies, cost counters (ADR-0040, PR-2)

The 2026-07-13 baseline audit found zero alerting and zero uptime
checks — an outage, error storm, latency collapse, or failed backup
would go undetected indefinitely, and the 99% availability SLO was
unmeasurable. ADR-0040 (Observability & Alerting Baseline) closes this
gap entirely in Terraform — no console-created resources, all
creates, no imports.

- **`terraform/observability.tf`** (new): two notification channels —
  email to `admin@chandraailabs.com` (Terraform-managed) and native
  SMS to the Coordinator's number (**console-owned operator config,
  Terraform-referenced read-only** via a `data
  "google_monitoring_notification_channel"` lookup on display name
  `"Coordinator SMS"` — mirrors ADR-0038's secret shells-vs-values
  pattern; the number never appears in the repo, in state, or in
  tfvars; creating the channel is a documented pre-apply step, and the
  data source fails plan loudly if it's missing, by design); two
  uptime checks (edge path via the reserved, tenant-independent
  `probe.slotsense.chandraailabs.com/health` — chosen over a real
  tenant subdomain since an unauthenticated `/health` probe never
  exercises tenant resolution anyway; service path via the Cloud Run
  URI directly — deliberately redundant so one red/one green localizes
  the fault layer); four alert policies wired to both channels (5xx
  rate > 5%/5min, p95 latency > 2500ms/15min, uptime check failure
  from ≥2 regions, Firestore backup failure); three log-based metrics
  (`firestore_backup_failures`, `voice_turns`, `agent_text_turns`);
  `google_project_service` for `clouderrorreporting.googleapis.com`
  (the one API the audit predicted would be missing —
  `monitoring.googleapis.com` was already enabled).
- **Health route verified from code, not assumed:**
  `backend/src/sport_slot/health.py:14` (`GET /health`, pure liveness,
  no dependency calls) — curled live against the edge host, returned
  200.
- **Turn counters built on Cloud Run platform request logs**, not
  application logs: verified against a real `/agent/query` log entry
  via `gcloud logging read`. The app's own structured logging has no
  unconditional per-turn event for text-agent turns (`voice.py` logs
  `voice_request_received` unconditionally; `agent.py`'s `/query`
  router and `orchestrator.run_agent` don't have an equivalent) — see
  backlog `AGENT-TURN-EVENT` for the follow-up.
- **`firestore_backup_failures` filter is defensive/provisional** — no
  real backup failure has occurred yet to observe the actual Cloud
  Audit Log shape; flagged for validation at the DR drill or first
  real failure.
- `terraform fmt`/`validate` clean (`init -backend=false`, local-only;
  a stale/expired credential cache blocked the backend-state read
  attempt entirely, confirming no backend contact was made). Import,
  plan, and apply are Coordinator-run and not yet executed.
- New runbook `docs/runbooks/observability.md`: what alerts exist,
  where they go, the SMS-channel pre-apply step (console creation +
  verification), and post-apply validation steps for the Coordinator.
  DR runbook §4.1 rebuild procedure updated to create the SMS channel
  before the first `terraform apply` pass.
- Backlog: `PR-2-OBSERVABILITY` and `BACKUP-ALERT` marked implemented
  pending apply/validation; added `BACKUP-ABSENCE-ALERT`,
  `ALERT-THRESHOLD-TUNE`, `AGENT-TURN-EVENT`; amended `SEC-HEADERS` to
  include the charter's CORS claim (noticed but out of scope during
  DOC-TRUTH).

**Production Readiness phase progress:** PR-1a ✓ → PR-1b ✓ →
DOC-TRUTH ✓ → PR-2 (this entry, pending apply) → PR-3 (Availability) →
PR-4 (Cost) → PR-5 (Security). Tracked in `docs/backlog.md`.

### docs/ci(DOC-TRUTH): reconcile claims with enforcement (pip-audit warn, gitleaks blocking), ADR-0039 accepted residuals, Phase 16/17 numbering, roadmap archived, review snapshots, backlog closures (IAM-TF-CODIFY, PROJECT-ASSESSMENT)

A 2026-07-15 third-party project review found the project's worst
credibility risk was doc drift: the security charter and README
claimed CI/infra controls (Binary Authorization, container scanning,
security headers, a "Phase 8 Production Readiness" that never shipped
in that slot) that neither CI nor infra actually enforced. This
sub-phase makes docs match reality, closes the review loop in the
canonical backlog, and formalizes phase numbering.

- **CI gates:** added `pip-audit` (non-blocking, `continue-on-error`,
  ratchets to blocking per backlog `CI-AUDIT-RATCHET`) and `gitleaks`
  (blocking, new `secret-scan` job) to `.github/workflows/pr-gates.yml`.
- **Doc reconciliation:** security charter and README/REQUIREMENTS
  claims for Binary Authorization, KMS signing, pnpm audit, container
  scanning, and security headers (confirmed absent from app middleware
  via grep — no HSTS/CSP/X-Frame-Options in `main.py`) downgraded to
  "Planned — Phase 17 PR-5", each dated "(status corrected 2026-07-16,
  DOC-TRUTH)"; CMEK/VPC+NAT/admin MFA/pen test claims now point to
  ADR-0039 instead of a stale "Phase 8" framing.
- **Roadmap archived:** `docs/roadmap.md` moved to
  `docs/archive/roadmap-2026-06.md` (frozen snapshot); a stub now
  points to `docs/backlog.md` (canonical) and this changelog (phase
  progress).
- **Phase numbering formalized:** verified via three independent
  forward-references to "Phase 16 DPDP self-assessment" (ADR-0036,
  ADR-0037, backlog) plus the Phase 13 retrospective's "two new
  phases locked in sequence" — Phase 16 = Voice I/O, Phase 17 =
  Production Readiness. Reflected in README's phase table,
  `docs/REQUIREMENTS.md`, and a new Phase 16/17 section in
  `docs/adr/README.md`.
- **ADR-0039** (Accepted Production-Hardening Residuals): CMEK,
  VPC+NAT for Cloud Run, admin MFA, and penetration testing deferred
  as one dated accepted-residual decision with explicit revisit
  triggers, replacing four silent open items.
- **Review snapshots:** the three `PROJECT_REVIEW*.md` files (sitting
  untracked at repo root) committed as dated snapshots under
  `docs/reviews/2026-07-15-*`, with a status-lives-in-backlog header
  and cross-reference links fixed for their new paths.
- **Backlog:** `IAM-TF-CODIFY` closed (✓ DONE — Phase 17 / PR #142);
  `PROJECT-ASSESSMENT` closed (✓ DONE — Phase 17 / third-party review
  + Strategist validation); `ROADMAP-STALE` closed (resolved by the
  archival above); added `HARDENING-RESIDUALS` (deferred, ADR-0039),
  `CI-AUDIT-RATCHET`, `SMOKE-E2E`, `CONTAINERREGISTRY-CLEANUP`, and
  `SEC-HEADERS`.
- **`terraform/firestore.tf` hygiene:** removed the stale commented-out
  `google_firestore_database` template (superseded by
  `terraform/backup_dr.tf`, ADR-0038); kept the `locals` block, since
  `terraform/outputs.tf` references both `local.firestore_database_name`
  and `local.firestore_location`. `terraform fmt`/`validate` clean
  (local-only, `-backend=false`; no state/backend touch — no other
  terraform commands run).
- **Protocol v3.8:** skipped this pass — `Protocol_v3_8_AMENDMENT.md`
  was not present in the repo and no base protocol document exists
  in-repo to amend either. Coordinator direction: ignore for now.

**Production Readiness phase progress:** PR-1a ✓ → PR-1b ✓ →
DOC-TRUTH (this entry, pending merge) → PR-2 (Observability) → PR-3
(Availability) → PR-4 (Cost) → PR-5 (Security). Tracked in
`docs/backlog.md`.

### feat(infra): Production Readiness PR-1b — codify SAs, IAM bindings, Cloud Run service, Redis, Artifact Registry (ADR-0038 Layer 3)

Completes ADR-0038 Layer 3 (IAM-TF-CODIFY): the four baseline service
accounts (`sa-cloud-run`, `sa-cloud-build`, `sa-firebase-admin`,
`sa-monitoring`) were only commented-out resource templates in
`terraform/iam.tf` (Phase 1.4.2 Option C) with active references held
as `data` sources — the SAs and every role binding were granted
imperatively via `gcloud iam` and would vanish on an infra rebuild.
They're now `google_service_account` resources; all 15 cross-file
references (`cloud_tasks.tf`, `invoice_export.tf`, `outputs.tf`,
`voice_stt.tf`, `wif_iam.tf`) are repointed from
`data.google_service_account.*` to `google_service_account.*`. Adds 16
`google_project_iam_member` resources (one per binding, audit-trail
style) for the six custom SAs' project-level roles, verified against
the live IAM policy with zero delta; the 3 bindings on
`firebase-adminsdk-fbsvc@` are Firebase-provisioned and documented as
an intentional D8 exclusion, not codified.

New `terraform/cloud_run.tf` brings `sport-slot-api` under management
as `google_cloud_run_v2_service`, authored field-for-field from the
live export (scaling ceiling **2**, matching live — raising it is
PR-3 scope, not this PR). Per the ADR-0038 D7 ownership model,
`lifecycle.ignore_changes` covers the image and the deploy-client
annotations/labels CI's `gcloud run deploy` rewrites every release, so
Terraform owns existence/shape while CI continues to own revisions.
`terraform/cloud_scheduler.tf`'s Cloud Run data source is removed in
favor of the new managed resource.

New `terraform/base_infra.tf` codifies the Memorystore Redis instance
(`sport-slot-redis`, BASIC tier, 1GB, `REDIS_7_0`) and the Artifact
Registry repository (`sport-slot-repo`, DOCKER), both previously
absent from state, matching live field-for-field. All new resources
carry `prevent_destroy`.

A completeness check (per-service `gcloud list`/`describe`, since
`cloudasset.googleapis.com` is not enabled and enabling it would be a
live project change out of this PR's zero-live-change scope) produced
a "Managed vs excluded inventory" appendix in
`docs/runbooks/disaster-recovery.md` §4.2, classifying every live
asset type as Terraform-managed, runbook-covered, or explicitly
excluded with a reason. The runbook's Layer 3 chapter now has the
ordered rebuild procedure for a new project, including the
Firebase-provisioning and Cloud-Run-image-bootstrap ordering gotchas
this PR's authoring surfaced. `docs/backlog.md` gains a
`ROADMAP-STALE` (cosmetic) entry — `docs/roadmap.md`'s phase tracker
predates the Voice and Production Readiness workstreams.

**Correction:** the PR-1a entry below states `docs/backlog.md` gained
7 entries; the correct count was 9. Noted here rather than edited into
that entry, per this project's no-history-editing convention.

`terraform fmt`/`validate` are clean; import, plan, and apply are
Coordinator-run and not yet executed.

**Production Readiness phase progress:** PR-1a ✓ → PR-1b ✓ (this
entry, pending Coordinator apply) → PR-2 (Observability) → PR-3
(Availability) → PR-4 (Cost) → PR-5 (Security). Tracked in
`docs/backlog.md`.

### infra(dr): Production Readiness PR-1a — Firestore backup/PITR, bucket versioning, secret shells; DR runbook skeleton (ADR-0038)

The 2026-07-13 baseline audit found zero Firestore recovery capability
(PITR disabled, no backup schedules), unversioned `tfstate`/invoice
buckets, and an incomplete Terraform rebuild path — unbounded RPO, no
credible 4h RTO. ADR-0038 (Backup & Disaster Recovery Strategy,
Accepted 2026-07-14) fixes RTO/RPO at 4h across six recovery layers.
This PR codifies the Layer 1 stop-gap (PITR + delete protection,
enabled imperatively on 2026-07-14 ahead of this ADR) plus a daily
backup schedule: new `terraform/backup_dr.tf` adds the
`google_firestore_database` resource, `google_firestore_backup_schedule`
(7-day retention), the `tfstate` bucket (imported, not created), and
secret shells for `redis-auth`/`resend-api-key` (metadata only — no
values, per protocol §2.6). `invoice_export.tf` gains versioning plus a
30-day noncurrent-version lifecycle rule. All four resources carry
`prevent_destroy`. Terraform is written to match live state
field-for-field so import produces a clean plan, not changes —
including a CONTEXT correction found during verification:
`sport-slot-dev-tfstate` already had versioning and a 30-version
lifecycle rule live, contrary to the original audit premise that no
bucket was versioned. `terraform fmt`/`validate` are clean; import,
plan, and apply are Coordinator-run and not yet executed. Added a
skeleton DR runbook (`docs/runbooks/disaster-recovery.md`) covering all
six ADR-0038 layers, a DNS rebuild chapter, and a timed-drill plan.
`docs/backlog.md` gains 7 entries for the rest of the phase (PR-2
Observability, PR-3 Availability, PR-4 Cost, PR-5 Security,
BACKUP-ALERT, AUTH-EXPORT-AUTO, SLO-LOAD-TEST, PROJECT-ASSESSMENT) and
elevates IAM-TF-CODIFY to IN PROGRESS as PR-1b.

**Production Readiness phase progress:** PR-1a ✓ (this entry) →
PR-1b (Terraform rebuild codification / IAM-TF-CODIFY, next) → PR-2
(Observability) → PR-3 (Availability) → PR-4 (Cost) → PR-5 (Security).
Tracked in `docs/backlog.md`.

### feat: up/down arrow walks full message history (AGENT-UX-01b)

AGENT-UX-01 (PR #132) only recalled the single most-recent user message
on ArrowUp, then stopped. Replaced with shell-style multi-level history:
`Assistant.tsx` now passes `MessageInput` the resident's full prior
user-message list (newest-first) instead of just the latest one.
`MessageInput` holds a history cursor — ArrowUp walks back one message
per press (stopping at the oldest), ArrowDown walks forward, and passing
back beyond the newest restores the draft that was in the box when the
walk started. Editing a recalled message and pressing ArrowUp again
discards the edit and keeps walking further back (shell/bash behavior).
The existing "never hijack a fresh typed draft" gate is preserved.
Cursor resets on send and on `/clear`. Frontend-only.

### chore: fix stale STT model probe (VOICE-PROBE)

`scripts/voice/stt_model_probe.py` was a 1b-era diagnostic that always
400'd ("Maximum number of allowed language codes is 3") because it sent
its 9-language candidate list on every probe row regardless of model —
misleading output during the 2026-07-13 debugging session. Replaced the
hardcoded matrix with a case matrix that validates the shipped config
first (chirp_2 @ asia-southeast1, en-IN only), plus regional-reachability
and future-VOICE-ML cases — none exceeding the API's 3-code cap (enforced
by an assertion on the case dataclass). A missing `--audio` clip
(including the default, gitignored fixture) now prints clear guidance —
how to pass an existing clip or record one via `ffmpeg` — instead of a
bare "file not found". Header docstring updated for current reality
(chirp_3 withdrawn). Read-only diagnostic, not wired into any app path or
CI gate.

### feat: stop TTS playback when mic input starts — barge-in (VOICE-BARGE-IN)

Voice mode could overlap the agent's spoken reply with the resident's own
mic input when they tapped to speak again before playback finished. The
user now takes priority: starting a recording immediately pauses any
in-progress reply audio (both the auto-played reply and a
manually-resumed fallback-button playback). Frontend-only —
`MessageInput` reports its recorder's `isRecording` up through
`Assistant` and back down through `MessageThread` to each
`MessageBubble`'s `AudioReply`, which pauses its own `<audio>` ref the
moment recording starts. No change to the recording pipeline, the voice
request, confirm routing, or text mode.

### infra: codify roles/speech.client for sa-cloud-run in Terraform (VOICE-IAM-TF)

The Cloud Run runtime SA's `roles/speech.client` grant (needed for voice
STT, ADR-0036/0037) was applied imperatively via `gcloud` on 2026-07-13
to fix a live 403. Added `terraform/voice_stt.tf` — a
`google_project_iam_member` resource matching the existing
`invoice_export.tf` / `cloud_tasks.tf` pattern — so the grant is codified
and replicates to Test/Prod on apply instead of drifting/vanishing on
infra rebuild. `terraform fmt`/`validate` clean; import/plan/apply is
Coordinator-run, not yet applied.

### chore: remove SPORTSLOT_VOICE_ENABLED feature flag

Voice is validated and working; the flag is deleted so `POST /agent/voice`
is unconditionally available in every environment, with no env var to
manage per deploy. No pipeline behavior change otherwise. With the flag
gone, no runtime gate prevents voice reaching prod — see VOICE-PROD-GATE
in `docs/backlog.md`.

### fix: strip Markdown from agent replies for clean text + TTS (AGENT-MD-TTS)

Agent replies could carry Markdown emphasis and bullet syntax (e.g.
`**Tennis Court - 1**`, `* Monday ...`) — harmless as rendered text, but
read aloud by TTS as "asterisk asterisk" now that voice is live. Added
`services/agent/text_format.to_plain_text`, a pure formatting-only helper
that strips bold/italic markers, headings, inline code/fences, and
normalizes bullet markers (`*`/`-`/`+`) to a consistent `- `, while
preserving all content, numbers, and line structure verbatim (a hyphen
inside text like "Court - 1" is never treated as a bullet). Applied once,
at the single shared boundary both `/agent/query` and `/agent/voice` flow
through (`run_agent` / `run_agent_confirm` in `orchestrator.py`) — no
change to any agent/tool logic or the data shown.

### feat: Voice I/O sub-phase 2 — mic capture + playback UI; AGENT-UX-01/02 (July 2026)

**Adds the resident-facing voice UI to the existing assistant surface.
Backend unchanged** — this sub-phase is frontend-only, built entirely on
the already-merged `POST /agent/voice` endpoint.

**Mic capture:** a new `useVoiceRecorder` hook wraps `getUserMedia` +
`MediaRecorder`, feature-detecting the supported `mimeType`
(`audio/webm;codecs=opus` preferred, `audio/mp4` for Safari, otherwise
the browser's own default — never assumed). `start()` resolves a `Blob`
once recording stops, whether stopped by the resident tapping again, a
hard 30-second ceiling, or best-effort silence detection (an `AnalyserNode`
RMS check) — the ceiling and tap-to-stop are the guaranteed controls;
silence detection is a convenience layered on top, and its own failure
(e.g. no `AudioContext`) never blocks recording. Never throws: permission
denial and an unsupported browser both resolve `null` and set a
human-readable `error` string instead.

**Voice is additive, never a regression on text.** A mic button sits
beside Send in `MessageInput`, disabled (not hidden) when unsupported or
when the input itself is disabled — the text input and Send button are
fully unaffected and keep working in every state (no microphone, denied
permission, unsupported browser).

**Spoken-confirm routing mirrors the existing tap-to-confirm path
exactly:** a voice turn is a CONFIRM turn iff the latest non-dismissed
agent message carries a live `pending_action_id` (the same key
`handleConfirm` already used) — that ID rides along with the audio to
`/agent/voice`, where the backend's deterministic guard (never an LLM)
decides. `decision` then drives the UI: `affirm`/`deny` dismiss the
pending message and append the result; `ambiguous` (or an empty/garbled
transcript, `decision: null`) re-prompts and explicitly KEEPS the pending
action alive — never guesses. A normal voice turn may itself propose a
new pending action, rendered via the existing `ProposalCard` exactly as a
typed turn would.

**Playback:** an agent reply carrying `reply_audio` auto-plays on arrival;
if the browser blocks autoplay, a `play()` rejection swaps in a visible,
labeled fallback button rather than failing silently. Reply audio is
decoded from the endpoint's base64 payload into a Blob and object URL
only in memory — `agentSession.saveThread` strips `audioUrl` before
writing to `sessionStorage` (a `blob:` URL wouldn't survive a reload
anyway; text and lightweight metadata like `reply_audio_mime`/`decision`
are kept).

**`lib/api.ts`'s `apiFetch` now skips the manual `Content-Type` header
when the body is a `FormData`** (the voice upload's multipart body) so the
browser can set the boundary itself — the existing JSON call sites are
unaffected.

**AGENT-UX-01** (up-arrow message recall) **and AGENT-UX-02** (`/clear`
slash command, instant, chat-app style, no confirmation) ship in the same
pass, per the backlog's own note that both were natural to do alongside
this UI work. Verified a cleared thread also drops any live
`pending_action_id` — it only ever lived as a field on a thread message,
so `setThread([])` clears it too; no separate cleanup path was needed.
Both marked done in `docs/backlog.md`.

Hermetic tests cover the recorder hook (mocked `MediaRecorder`/
`getUserMedia`), the multipart mutation (`FormData` construction), the
mic button and its states, autoplay + fallback playback, the full
confirm-routing decision matrix (affirm/deny/ambiguous/empty-transcript),
up-arrow recall, and `/clear`. The axe-core accessibility audit stays
green, including two new checks added specifically for states the
existing audit's default thread never exercised (the recording/"Listening…"
state, and an agent bubble actually carrying `reply_audio`).

### feat: Voice I/O sub-phase 1c — POST /agent/voice endpoint, English-only (July 2026)

**Wires the full voice turn end-to-end: audio → STT(en-IN) → [confirm
guard | run_agent] → TTS(en-IN) → audio.** Feature-flagged, default OFF
(`SPORTSLOT_VOICE_ENABLED`, unset/false → the endpoint 404s, behaving as
if it does not exist). English-only for this sub-phase — translation
(ADR-0036 D1) and per-tenant language configuration (ADR-0037 D3′) are
staged, not built: every language decision already routes through the
new `services/voice/languages.py` resolver
(`resolve_tenant_voice_languages`, returns `["en-IN"]` today), so only
that one seam changes when the multi-language sub-phase ships.

**Live-verified before any pipeline code was built on it** (the same
fail-fast discipline that caught the withdrawn `chirp_3` / regional
`chirp_2` STT issues in 1b): enabled `texttospeech.googleapis.com`,
enumerated the available `en-IN` Chirp 3 HD voices (30 found), and made
one real synthesis call — `en-IN-Chirp3-HD-Kore` returned 7,776 bytes of
valid MP3 audio. Chirp 3 HD runs at the global/eu/us endpoints, not
asia-southeast1 (the STT endpoint) — the same documented residency
exception already accepted for STT (ADR-0036 D5 / ADR-0037 D5′), now
extended to TTS, via the default (global) `TextToSpeechClient` endpoint.

**New modules** (all in `services/voice/`, 100% hermetic coverage,
`services/voice/` mypy-scoped and clean):
- `languages.py` — the ADR-0037 D3′ staging seam.
- `tts.py` — `synthesize(text, language_code) -> (audio_bytes, mime)`,
  raises a defined `TtsError` on failure; never fed raw tool dispatch
  output, only the agent's already-prose reply text.
- `voice_pipeline.py` — `run_voice_turn(...)`, the orchestrator, plus
  `combine_confirm_decisions` (ADR-0037 D2′): the confirm turn checks
  the utterance against **all** of the tenant's configured languages'
  lexicons (today: just English), not only whichever language STT
  guessed — any AFFIRM and no DENY → AFFIRM; any DENY and no AFFIRM →
  DENY; both or neither → AMBIGUOUS, fail-closed. AFFIRM calls the
  existing `run_agent_confirm` unmodified; DENY abandons the pending
  action with no new delete path (it expires via its existing ADR-0025
  TTL); AMBIGUOUS re-prompts and keeps the pending action alive. An
  empty/garbled transcript never guesses — it re-prompts and leaves any
  in-progress confirmation exactly as it was. `run_agent` /
  `run_agent_confirm` (the existing text agent) are called exactly as
  the text endpoint calls them — no new agent behavior, only a new edge
  in front of the same, unmodified pipeline (ADR-0036 D1). TTS failure
  degrades to a text-only reply; the turn still succeeds.

**New endpoint:** `api/v1/voice.py`, `POST /agent/voice`, residents-only,
multipart (`audio` file + optional `pending_action_id` form field), a
configurable audio size cap (`SPORTSLOT_VOICE_MAX_AUDIO_BYTES`, default
2 MB, rejects oversized uploads with a new `PAYLOAD_TOO_LARGE` error
code before any pipeline work runs), and rate-limited via the existing
app-wide default limiter — the same mechanism `/agent/query` and every
other authenticated route already use, no bespoke per-route limiter
added. Registered in `main.py` exactly like the existing agent router;
`/agent/query` itself is completely unchanged.

Adds `google-cloud-texttospeech` and `python-multipart` (both pinned) as
new dependencies.

### fix: professional prose for agent invoice replies (July 2026)

**Presentation only — no value, period, currency, or data-shown change.** The
AI booking agent's two invoice tools (`get_my_invoices`,
`get_my_current_month_charges`) were leaking raw key=value debug text
directly to residents, e.g. `total_invoices=1 period=2026-07
total=₹2400.00`, while every other agent reply reads as clean prose. Root
cause: ADR-0035 Decision 9's deterministic pre-Vertex invoice router
returns these two tools' dispatch strings directly as the final reply,
skipping the normal Gemini rephrasing turn (by design, for reliability) —
so unlike `list_my_bookings`/`get_my_preferences` (which are always
Gemini-rephrased before reaching a resident, despite using the same
internal key=value shape), these two tools' raw internal strings were the
literal, unprocessed resident-facing text.

Reworded both tools' reply branches in `services/agent/orchestrator.py`
to natural, TTS-safe prose (relevant ahead of the voice work — these
strings will later be read aloud): "no invoices" → "You don't have any
invoices yet."; a single invoice → "Your most recent invoice is for July
2026: ₹2,400.00."; multiple → a lead line + one prose line per invoice
(there is no per-period lookup in the underlying tool — it always
returns the N most recent, so wording never claims a specific-month
query that doesn't exist); the current-month live preview → "So far in
July 2026 you have 15 bookings totalling ₹2,100.00. This is a live
preview, not a final invoice." Periods are now spoken as words ("July
2026") via a new `_format_period` helper, never the raw ISO form.
Amounts, counts, and periods are unchanged — every reworded test asserts
the same numeric values/periods still appear in the new prose. The two
JSON error branches were deliberately left untouched: confirmed via the
code's own `is_error` check that they're intercepted and replaced with
the safe fallback before ever reaching a resident, so rewording them
would be scope creep with no user-visible effect.

### feat: Voice I/O sub-phase 1b — STT ingestion + language detection (July 2026)

**Standalone module, no endpoint/translation/TTS/agent wiring yet.** Adds
`services/voice/stt.py` (`transcribe(audio_bytes, language_codes) -> SttResult`),
the first stage of the ADR-0036 D1 speech → STT → translate → agent →
translate → TTS pipeline. Uses Speech-to-Text API V2 sync `recognize` and
`AutoDetectDecodingConfig` (no fixed container assumed — browser audio
arrives as WebM/Opus or MP4/AAC depending on client platform). Detected
BCP-47 codes are normalized to 2-letter form; `is_supported_language` is
computed against the platform's nine-language set, the same one the
confirm/deny guard curates (`confirm_lexicon_data.CONFIRM_LEXICON`),
avoiding a second hardcoded list. Errors from the SDK propagate as a
defined `SttError`, never a bare crash; an empty result set returns an
empty `SttResult` rather than raising.

**Model and endpoint went through two live-measurement corrections before
merge (ADR-0037, twice-revised) — final state below, corrected in place
rather than left as a known-broken entry.** This sub-phase originally
specified `model="chirp_3"` at the `global` recognizer location,
auto-detecting across the full nine-language set in one call (ADR-0036
D3/D5). Live testing against the real API found:

- `chirp_3` is withdrawn: rejected as "does not exist" everywhere tested
  (`global`, `us-central1`, `europe-west4`, `us`, `eu`); at `asia-south1`
  and `europe-west2` (the regions it was previously scoped to) the API
  returns `403 ... It is no longer generally available` — GA-revocation,
  not a permission or preview-enrollment gate (the same principal
  succeeds against other models seconds later).
- Candidate-list auto-detection across more than 3 language codes does
  not exist anywhere on this API version: capped at 3 codes, and only
  offered at the `eu`/`global`/`us` multi-region endpoints.
- `chirp_2` (GA) was tried at `global` next, but a further live probe
  found `chirp_2` is itself REGIONAL: rejected as "does not exist" at
  `global`/`us`/`eu`, accepted at `asia-southeast1`.

**Final state:** `model="chirp_2"` (GA) at the **`asia-southeast1`**
regional endpoint (explicit `api_endpoint`, not the SDK default), shipping
**single-code English-first** recognition — the caller passes exactly one
BCP-47 code. `stt.py` validates `1 <= len(language_codes) <= 3` (the API's
hard cap) so the signature and validation are already correct for a future
multi-language sub-phase without another change; that sub-phase would also
need to revisit the endpoint back to `eu`/`global`/`us`, since
`asia-southeast1` (like the other Asia-adjacent GA endpoints) accepts only
one language code per call — no candidate-list auto-detection there.
Multi-language (Indic) auto-detection across a tenant's candidate set is
therefore **deferred**, not shipped in this sub-phase. Non-English
transcription quality is validated post-deploy (sub-phase 3), not a
pre-merge blocker — English acceptance against the real API at
`chirp_2`/`asia-southeast1` is proven.

Adds `google-cloud-speech` (pinned) as a new dependency. Adds a
Coordinator/ADC-run live measurement harness,
`scripts/voice/stt_live_check.py`, which prints a
file/container/transcript/detected-lang/confidence/ok table over a
fixtures directory, deriving WebM/AAC variants via `ffmpeg` when available
to prove cross-container decode.

Adds `mypy` to CI, scoped deliberately to `services/voice/` only (see
`pyproject.toml` `[tool.mypy]` and `.github/workflows/pr-gates.yml`) — the
rest of the codebase predates this gate and is out of scope for this
sub-phase.

100% coverage on `stt.py` (hermetic tests, `SpeechClient` mocked — no real
API calls in the test suite).

### feat: Voice I/O sub-phase 1a — ADR-0036 D2 deterministic confirm/deny guard (July 2026)

**Standalone module, no endpoint wiring yet.** ADR-0036 established that the
spoken confirmation turn cannot be a translate/LLM turn — a mistranslated
"no" would breach the propose-confirm-execute gate (ADR-0023) — so it must
be interpreted deterministically, extending ADR-0026 (deterministic Python
guards over LLM judgment) to a new case: confirmation interpretation.

Adds `services/voice/confirm_guard.py` (`classify_confirmation`, pure
function, fail-closed to `AMBIGUOUS`) and `services/voice/confirm_lexicon_data.py`
(per-language affirm/deny token lists for the nine ADR-0036 D3 languages:
en, hi, te, ta, kn, ml, mr, gu, bn — native script and romanized forms).

Matching is whole-word/whole-phrase, never naive substring. Notably, Python's
regex `\b` word boundary is unusable here: `\w` excludes Unicode combining
marks, which several of these scripts use for vowel signs and anusvara
(e.g. Devanagari `नहीं`), so a `\b`-based match silently breaks mid-word.
Matching instead tokenizes on whitespace with per-token punctuation
stripping. A two-sided test proves the guard does real safety work: a naive
`"yes" in transcript` baseline false-affirms on inputs like `"yes, nevermind"`
while the guard correctly returns `AMBIGUOUS`.

100% coverage on both new files. The non-English lexicon lists are seed
content only — flagged COORDINATOR-REVIEW-REQUIRED (native-speaker pass)
before sub-phase 1b, which wires this guard into the `/agent/voice`
endpoint (D7).

### feat: Phase 15.7 — ADR-0034 invoice-exclusion carve-out for tenant/user deletion (July 2026)

**The final piece of Phase 15** — wiring in an obligation flagged since Phase 13.3/13.4, before the
`invoices` collection even existed. Both affected functions carried explicit "when Phase 15 ships,
update this" comments written back when the carve-out was still hypothetical.

**`delete_user_permanently` (services/provisioning.py) needed no code change.** Confirmed via
investigation: it only ever queries `bookings` filtered by `uid` and never touches `invoices` at
all — structurally can't, since invoices live in a completely separate tenant subcollection keyed
by `household_id`, never referenced by this function. The stale comment is replaced with an
accurate one explaining why.

**`delete_tenant_permanently` (services/tenants.py) was the real risk.** A single
`client.recursive_delete(tenant_ref)` wipes the entire Firestore subtree indiscriminately —
invoices included, with no way to exclude a path from one call on the parent document. Fixed by
dynamically enumerating the tenant's ACTUAL subcollections at runtime via
`tenant_ref.collections()` — deliberately **not** a hardcoded list (e.g.
"bookings, users, facilities, audit"), which would silently miss any subcollection added in a
future phase and quietly reintroduce this exact gap. `recursive_delete` is now called individually
on every enumerated subcollection except `invoices`, followed by a plain `.delete()` on the
now-childless tenant document itself (not `recursive_delete` — nothing remains beneath it except
the deliberately-preserved `invoices` subcollection, a Firestore sibling, not something "inside"
the document a plain delete would touch).

**Per locked Coordinator decision, the tenant document itself is still fully deleted** —
orphaned invoices (no parent tenant doc) are explicitly acceptable; Firestore permits querying a
subcollection by full path regardless of whether its parent document still exists. This is not a
soft delete.

**The regression test that actually proves dynamic-over-hardcoded enumeration**: a fixture
seeds a hypothetical `waitlists` subcollection that appears in no hardcoded list anywhere in this
codebase, and asserts it IS still recursive-deleted (with its document count correctly included in
the total). A hardcoded-list implementation would silently skip it entirely and fail this specific
assertion. A separate test confirms `invoices` is never passed to `recursive_delete` even when
present as a real, enumerated subcollection with a non-zero document count.

### fix: deterministic pre-Vertex routing for invoice queries (July 2026)

**A confirmed, live-reproduced reliability bug — not a wording issue, not a stale deploy, both
explicitly ruled out this session.** Identical phrasing ("my invoice please") worked correctly in
one fresh session and failed in another, with the exact same 15.6 system-prompt routing
instructions in place both times. This is genuine Gemini function-calling non-determinism for
INITIAL tool selection — a different problem from the cancel flow's existing determinism
(ADR-0026/ADR-0027), which only prevents hallucinating *which* booking to act on after Gemini has
already chosen to call `cancel`; it has never made the initial tool-selection decision itself
deterministic for any tool. A full-tree grep confirmed no retry logic, forced/mandatory
function-calling mode, or fallback mechanism existed anywhere in `services/agent/` to catch this.

**Fix:** a second pre-Vertex interception block in `run_agent`, same structural shape as the
existing cancel-disambiguation check it sits beside. A conservative, whole-word keyword match
(`invoice`, `invoices`, `bill`, `bills`, `owe`, `owed` — none collide with any other tool's
phrasing space) skips Vertex **entirely, both turns**, and dispatches directly to the exact 15.6
`get_my_invoices`/`get_my_current_month_charges` functions, sub-classified by "this month"/"so
far"/"till date"/"current month" phrasing. Deliberately narrow: invoice tools only — generalizing
this to other tools (`check_availability`, `book`, `cancel`, etc.) is an explicitly separate,
undecided future discussion.

**Additive only, proven by call-count, not just absence of error:** a non-matching message (e.g.
"book tennis tomorrow") is asserted to still call Vertex exactly as today. The four literal
phrasings confirmed failing live this session are each asserted to call Vertex **zero** times. The
full pre-existing agent test suite (143 tests across `test_agent.py`, `test_agent_booking.py`,
`test_agent_cancel.py`, `test_agent_preferences.py`) passed with **zero modifications** — the only
two touched tests (in 15.6's own `test_agent_invoices.py`) needed their input *wording* changed
because they happened to use phrasings that now correctly match the new deterministic path by
design, not because anything broke.

### feat: Phase 15.6 — read-only agent invoice tools (July 2026)

**What:** The agent can now answer invoice questions, per Phase 15's original requirement ("what
is my latest invoice (of the month till date), previous month invoice, etc."). Two new tools,
mirroring how `list_my_bookings` and `get_my_preferences` are kept as distinct, narrowly-scoped
tools rather than one do-everything tool:

- `get_my_invoices` — recent, already-GENERATED invoices (optional `count`, default 3), most-recent-
  first. Dispatches directly to `InvoiceRepository.list_for_household` (15.4) — zero new
  computation logic.
- `get_my_current_month_charges` — a LIVE, unofficial "so far this month" total, directly matching
  the original requirement's "of the month till date" wording. Dispatches directly to
  `preview_current_month_charge` (15.4c). The response text always frames itself explicitly as a
  live preview ("LIVE PREVIEW, not a final invoice"), never letting the model imply it's an
  official bill.

**Both are read-only, dispatched directly** — same pattern as `check_availability`/
`list_my_bookings`, no propose-confirm-execute step, since neither mutates anything. Both are
strictly scoped to `ctx.household_id` (never a household_id/tenant_id argument from the LLM's tool
call). Money is always shown to the user in ₹ rupees, never raw paise.

**System prompt updated** with routing rules for both tools (mirroring the existing "if user asks
about X, call Y" style exactly), plus a necessary carve-out: the pre-existing rule "Do not discuss
pricing, refunds, policies, or unrelated topics" would otherwise have directly blocked the agent
from ever using these new tools — it now explicitly permits discussing the user's own invoice
totals, but only via the two tools, never an invented or estimated amount.

**Tests directly exercise household isolation two-sided** for both tools: `get_my_invoices` against
a real fake-Firestore fixture seeded with two households' invoices (asserts the other household's
period/total never appears in the response text); `get_my_current_month_charges` asserts the
dispatch wiring passes `ctx.household_id` specifically for each distinct caller (its own
`preview_current_month_charge` household-filtering is already exhaustively tested in 15.4c).

### feat: Phase 15.5 — invoice CSV/JSON export + manual generation/export triggers (July 2026)

**Closes the "15.3b" gap.** Phase 15.3 planning flagged, but never built, a manual invoice
GENERATION trigger — if the scheduled monthly run failed for a tenant, there was no recovery path
at all. This sub-phase closes it: `regenerate_for_tenant` (services/invoicing.py) is a thin,
tenant-scoped wrapper around the existing `_generate_for_tenant` core, exposed as
`POST /api/v1/invoices/tenant/regenerate` — tenant-admin only, strictly scoped to `ctx.tenant_id`
(the function has no parameter for any other tenant, by construction). Defaults to the previous
calendar month, same as the scheduled job, and — because it calls the same shared core — also
triggers automatic export on completion, identically to the scheduled path.

**Automatic summary-level export (CSV + JSON)** now fires after every tenant's successful monthly
generation (scheduled OR manual), landing in a new, genuinely PRIVATE GCS bucket
(`sport-slot-dev-invoices`, Terraform prepared, **not yet applied**) — never the existing public
frontend bucket. Export is summary-level only (`household_id`, `flat_number`, `period`,
`total_paise`, and a rounded `total_rupees` convenience field) — deliberately no line-item detail,
per the original requirement. A separate, independent `POST /api/v1/invoices/tenant/export` route
lets a tenant-admin manually re-trigger just the export step (e.g. files were deleted from GCS but
the invoices themselves are fine) without re-running generation.

**Signed URL download without a service account key file.** `GET /api/v1/invoices/tenant/export/download`
returns short-lived (15 min) signed URLs for the CSV/JSON files. Cloud Run's default credentials have
no private key to sign a GCS URL with directly — this uses `google.auth.impersonated_credentials`,
having the SA impersonate ITSELF (a new self-referential `serviceAccountTokenCreator` grant,
Terraform prepared, not applied), the exact same keyless mechanism already working for Firebase
Hosting deploy tokens (`wif_iam.tf`'s `ci_token_creator_firebase`), just self- rather than
cross-referential this time.

**New `InvoiceRepository.list_for_tenant_period`** fetches every household's invoice for one
period (distinct from `list_for_household`, one household/all periods, and
`list_latest_per_household`, whole tenant/latest period only) — a single equality filter, no new
composite index needed.

**All three new tenant-admin routes are tested for cross-tenant isolation directly**: an attempted
`tenant_id` query-param injection is asserted to be ignored (none of the routes has such a
parameter — they only ever read `ctx.tenant_id`), and a resident (non-admin) caller is rejected
with 403 on all three. The signed-URL mechanism is tested by asserting the actual impersonation
call (`source_credentials`/`target_principal`/`target_scopes`), not just that a URL string came
back. A manual re-export of the same period is asserted to produce byte-identical CSV/JSON content
to what the automatic export produced.

**Terraform prepared (`fmt`/`validate` clean) but NOT applied** — the new bucket and the
self-impersonation IAM grant are not live until the Coordinator runs `terraform apply`; the export
and signed-URL features are not functional in production until then.

**Correction (same PR, caught before merge): `flat_number` could get permanently stuck on
`None`.** `_compute_household_charges` locked a household's `flat_number` onto whichever resident
was encountered FIRST while iterating bookings — even if that specific profile lookup failed (e.g.
a deleted account). Confirmed via live production data: a household with one old booking from a
deleted account and newer bookings from a currently-active resident still showed "Unknown flat" on
the invoice, even though the active resident's `flat_number` was available from a later booking in
the very same household/period. Fixed to only lock in a RESOLVABLE `flat_number` — a household now
only stays unresolved if literally every resident encountered in it is unresolvable, not just the
first one.

### feat: Phase 15.4c — per-flat invoice history + current-month preview (July 2026)

**Expands 15.4b's original "latest only, no history" decision.** That scope was a deliberate
simplification at the time — but real usage surfaced a genuine gap, not a bug: a tenant-admin
resolving a resident dispute needs more than the single latest invoice. They need (a) recent
history for that flat, and (b) visibility into the CURRENT, not-yet-invoiced month's bookings,
since disputes often surface before that month's invoice has even generated. This sub-phase adds
both, as a named evolution of 15.4b rather than treating "history" as having always been in scope.

**History** reuses `InvoiceRepository.list_for_household` (built in 15.4) completely unchanged —
a new tenant-admin route, `GET /api/v1/invoices/tenant/history?household_id=...`, just calls it
with `limit=3` against an arbitrary household (not `ctx.household_id`, unlike the resident-facing
`/mine`). Minimal new backend work, since the method already did exactly what was needed.

**Current-month preview required a real refactor, not just a new endpoint.** The core per-household
grouping/pricing/resident-resolution logic that used to live inline in `_generate_for_tenant` is now
its own function, `_compute_household_charges`, called identically by the real monthly generator
(which persists the result via `create_if_absent`) and by the new `preview_current_month_charge`
(which computes the SAME thing for the current, in-progress month and returns it — writing nothing
to Firestore). One source of truth for "what does this household owe," so the preview and a real
invoice can never silently drift apart (protocol §5.14). The extraction was verified
behavior-preserving by running the full pre-existing `test_invoicing_service.py` suite immediately
after the refactor — all 18 tests passed unmodified before any new test was added.

`TenantInvoices.tsx` (15.4b) is extended rather than replaced: clicking a flat's row reveals both
its last 3 generated invoices and its live current-month preview inline. The preview is visually
distinguished with an explicit `Badge` reading "Preview — not yet invoiced," so a tenant-admin can
never mistake a live, unofficial computation for a real, immutable invoice document.

**Regression tests directly exercise the real risk in this sub-phase**: the preview writes nothing
to Firestore (asserted against the fake client's backing store, not inferred from the response
shape), a newly confirmed current-month booking is reflected correctly in the preview's total, and
a resident (non-admin) caller is rejected with 403 on both new routes.

### feat: Phase 15.4b — tenant-admin latest invoice per flat (July 2026)

**What:** Tenant-admins can now look up any resident's latest billing status by flat number, to
help resolve resident disputes ("why is my invoice this amount"). A new tenant-admin-only route,
`GET /api/v1/invoices/tenant/latest` (added to the existing `api/v1/invoices.py`, guarded by
`require_role("tenant_admin")`), and a new `InvoiceRepository.list_latest_per_household` method
fetch **all** of the tenant's invoices in a single query, group them by `household_id` in Python,
and keep only the max-`period` invoice per household — `period`'s `"YYYY-MM"` format is
lexicographically sortable, so a plain string comparison picks the latest with no date parsing.
Households with no invoices simply don't appear (consistent with the zero-charge-skip philosophy
already established in 15.3). **Needs zero profile lookups**: `flat_number` and `resident_name`
are already denormalized onto every invoice document at generation time by the 15.3 correction, so
this is a single read + in-memory grouping regardless of tenant size — if this sub-phase had needed
a profile join, that would have signaled the 15.3 correction hadn't landed as assumed.

**Explicitly latest-only, no history drill-down** — a locked Coordinator decision to keep the admin
view simple; full per-household invoice history is out of scope (and out of scope for any near-term
follow-up).

`TenantInvoices.tsx` (new) mirrors the established bare-`<AppHeader />` + "← Dashboard" tenant-admin
page structure (`TenantFacilities.tsx`/`TenantUsers.tsx`), with a client-side flat-number search
filter mirroring 13.5's exact pattern (`TenantUsers.tsx`/`TenantList.tsx`). `TenantDashboard.tsx`
gains a new `NAV` entry linking to it, matching the array's existing `{to, title, desc}` shape.

**Regression tests directly exercise the two real correctness/security boundaries**: a fixture with
two periods for one household asserts only the newest is ever returned (never the superseded one),
and a resident (non-admin) caller is asserted to get a 403 from this tenant-wide route, not just
assumed to be blocked.

### feat: Phase 15.4 — family invoice summary UI (July 2026)

**What:** Residents can now see their own household's invoices, generated by Phase 15.3's
engine. A new `GET /api/v1/invoices/mine` route (mirroring `/bookings/mine`'s naming/auth
convention) and a new `InvoiceRepository.list_for_household` method return the caller's
invoices only, ordered most-recent-period-first — strictly scoped to `ctx.household_id`
(the `household_id` already carried on every authenticated resident's `TenantContext`, no new
auth plumbing needed). The repository method guards explicitly against a missing/`None`
`household_id`, returning empty rather than ever issuing a Firestore query with it. A new
`MyInvoices.tsx` page (mirroring `MyBookings.tsx`'s exact structure) lists each invoice's
period and ₹ total (converted from `total_paise`, matching 15.1's established
`paise / 100` display convention exactly) with an expandable line-item breakdown (facility
name, date, price). Two distinct empty states: no `household_id` on the account at all, vs.
`household_id` present but zero invoices yet.

**ResidentNav gains a third link (Invoices).** Since `ResidentNav` is a shared component,
`Facilities.tsx`, `Assistant.tsx`, and `MyBookings.tsx` all correctly pick up the new link as
a natural consequence — not scope creep, a locked Coordinator decision. Only
`ResidentNav.test.tsx`'s own link-count assertion needed updating (2 → 3); `Facilities.test.tsx`
and `MyBookings.test.tsx` assert specific hrefs only, so they were unaffected and left as-is.

**Cross-household isolation is tested directly**, not assumed: fixtures seed two different
households' invoices in the same fake Firestore collection, and both the repository method and
the `/invoices/mine` route are asserted to return only the caller's own household's data.

**Out of scope (unchanged):** any tenant-admin invoice browser across households, CSV/JSON
export (deferred to 15.5), and invoice generation logic itself (15.3, untouched — this
sub-phase only reads existing invoice documents).

### feat: Phase 15.3 — invoice generation engine (July 2026)

**What:** The core of Phase 15 — turns priced facility bookings into actual per-household
invoices. A new Cloud Scheduler job (new dedicated `sa-scheduler-invoker` service account,
matching this project's one-SA-per-trust-boundary convention) calls a new internal endpoint,
`POST /internal/invoicing/generate`, guarded by a new `verify_scheduler_oidc` auth dependency
(`auth/scheduler_auth.py`) that mirrors `verify_tasks_oidc`'s exact OIDC-verification structure
against the new SA identity. `services/invoicing.py` does the actual computation: for each active
tenant, it queries confirmed bookings dated in the previous calendar month (postpaid billing),
groups them by the `household_id` already present on every booking document, sums `price_paise`
per household — skipping bookings against unpriced facilities entirely (not a Rs.0 line item,
simply absent) — and writes one immutable invoice document per household via Firestore `create()`
on the deterministic ID `{household_id}_{YYYY-MM}`, which gives natural idempotent re-run safety
(a second run for the same period silently skips households that already have an invoice, no
error). Tenant- and household-level failures are isolated with per-item try/except and loud
`structlog` logging — one household's or tenant's failure never blocks the rest of the batch —
and the job returns a structured summary (tenants processed, households invoiced, households
skipped, households failed with reasons).

**Correction (same Phase 15.3, applied after initial merge): denormalized resident + flat
identity onto the invoice at generation time.** The original cut grouped bookings by
`household_id` alone — an internal code, not guaranteed human-readable or even derivable from
`flat_number` (the bulk-import path allows an explicit `household_id` override) — and gave no way
to tell which specific resident of a shared household made each booking, which is essential for
dispute resolution. Fixed by adding a `UserProfileRepository` lookup **inside** `_generate_for_tenant`,
cached per unique `uid` within one tenant's generation pass (one Firestore read per resident, not
per booking — verified directly by asserting the fake profile collection's call count, not just
the output). Each line item now carries `resident_uid`/`resident_name`; each invoice document now
carries `flat_number`, sourced from the first resident encountered for that household. Resolved
once, at generation time, deliberately — never at display/read time, which would mean a live
profile lookup on every invoice-list page view instead of one flat document fetch, expensive at
real scale (hundreds/thousands of flats per tenant). A missing/deleted profile falls back to
`"Unknown resident"` / `null` rather than crashing generation. The two invoices already in
Firestore from earlier manual verification were left untouched — they simply predate these
fields; display code (this correction's own `MyInvoices.tsx` update, and the future tenant-admin
view, 15.4b) must treat both fields as optional.

**Four deliberate, known gaps (not oversights):**
1. **Per-tenant generation time not yet honored.** Phase 15.2's `policies.invoice_generation_time`
   field exists and is stored, but this sub-phase runs on ONE fixed global Cloud Scheduler
   schedule (03:00 UTC on the 1st) for every tenant. Wiring per-tenant schedules is deferred to a
   later sub-phase.
2. **Invoices are immutable — no correction mechanism yet.** There is no update/PATCH path for an
   invoice document. Corrections (adjustments/credit entries) are unbuilt, future scope.
3. **No payment status tracked anywhere.** This system generates the bill amount only; whether or
   how an invoice gets paid is entirely the concern of an external "next level" system. No
   paid/unpaid field exists on the invoice document by design.
4. **New Terraform requires a manual Coordinator apply.** `terraform/cloud_scheduler.tf` (new
   `sa-scheduler-invoker` SA, its `run.invoker` IAM binding, and the `google_cloud_scheduler_job`
   resource) and a new Firestore composite index (`infrastructure/firestore.indexes.json`, for the
   `(status, date)` booking range query) are both prepared (`terraform fmt`/`validate` clean) but
   **not applied**. This sub-phase is not functional in production until the Coordinator runs
   `terraform apply` and deploys the Firestore index.

### feat: Phase 15.2 — invoice generation time policy (July 2026)

**What:** Tenant-admins can now configure the TIME of month invoices generate, via a new
`invoice_generation_time` field on `PoliciesPatch` (`tenant_config.py`), validated with the same
`_HHMM` regex already used for `booking_window_open_time` (no new/duplicate validator). Default
is `03:00`. The day-of-month remains fixed at the 1st — not configurable in this sub-phase, by
explicit Coordinator decision; the previously-documented `billing_cycle_type`
(postpaid/prepaid/biweekly) + anchor-day flexibility was decided against and stays unbuilt.

`TenantPolicies.tsx` follows the existing 4-field Policies pattern exactly: the new field is wired
into all three required points — initial `useState("03:00")` default, the `useEffect` pre-fill
from `usePolicies()`, and the `submit` payload — verified individually so it doesn't repeat the
partial-wiring/fetch-on-mount bug fixed earlier for the other 4 fields. New form input matches the
existing `booking_window_open_time` HH:MM text input exactly.

**Scope:** Policy field only. Invoice generation itself (15.3) and day-of-month configurability
(explicitly rejected for this phase) are out of scope.

### feat: Phase 15.1 — per-facility pricing configuration (July 2026)

**What:** Facilities gain an optional `price_paise` field (`FacilityCreate`, `FacilityUpdate`,
and the stored Firestore document in `facilities.py`) — always an integer number of paise, never
a float rupee value, per the project's fintech-standard money-storage convention. The field is
nullable and defaults to `None`; it is never defaulted to `0`, which would be indistinguishable
from "free." Existing facilities created before this change are unaffected — `price_paise` is
simply absent/null on them, with no backfill or migration.

The tenant-admin-facing "Add a facility" form and the edit-facility dialog (`TenantFacilities.tsx`)
both gain a "Price per booking (₹, optional)" input. The admin types the price in rupees; the
frontend converts to integer paise (`Math.round(rupees * 100)`) before calling the create/update
mutation, and leaves the field un-set (not `0`) when left empty. The facility list displays the
price formatted in rupees (`₹50.50`) when set, or a distinct "No price set" indicator when not —
never a misleading `₹0.00` for an unpriced facility.

**Scope:** Facility pricing configuration only. Billing-cycle policy, invoice generation, and any
resident-facing display of price are out of scope for this sub-phase (tracked separately as
Phase 15.2/15.3).

### feat: shared resident nav — Facilities + My Bookings always visible on all resident pages (July 2026)

**What:** `Facilities.tsx`, `Assistant.tsx`, and `MyBookings.tsx` each built their own header nav
independently and inconsistently: `Facilities.tsx` had a proper shadcn `Button asChild` link to My
bookings but no way back to itself (moot) or to Assistant; `Assistant.tsx` used a raw inline-styled
`<Link>` (not the design system) to Facilities, with no link to My bookings; `MyBookings.tsx` had
no header nav at all — only a manual page-body "← Facilities" text link, which is why a resident
had to hunt for the way back. New shared `ResidentNav` component (`components/ResidentNav.tsx`)
renders both "Facilities" (`/`) and "My bookings" (`/bookings`) links, styled consistently with
the shadcn `Button asChild` pattern (the version Facilities.tsx already had right). All three
pages now pass `<ResidentNav />` as `AppHeader`'s children instead of building their own; no page
keeps independent nav-building code. `MyBookings.tsx`'s redundant manual back-link is removed —
the header now covers it.

**Scope:** Resident-facing pages only (Facilities, Assistant, MyBookings). Tenant-admin pages
(`TenantDashboard`, `TenantUsers`, `TenantFacilities`, etc.) use a different, intentional
Admin-Dashboard-hub navigation pattern and were not touched. `FacilityAvailability.tsx` has a
similar gap (no `AppHeader` at all, just a manual back-link) but was confirmed out of scope for
this change — flagged for a separate follow-up.

### fix: Daily Booking Overview — full-width layout, mobile date input, sticky-column overlay, tooltip trigger area (July 2026)

**Bugs (all found during live Coordinator testing after the initial merge, confirmed via source
inspection, not assumed):**

1. **Full-width layout:** the page wrapper used `max-w-5xl`, inherited from other tenant-admin
   pages built for narrow forms — capping a wide data grid at that width wasted significant
   screen space on desktop/tablet (confirmed via live screenshot). Widened to `max-w-7xl`,
   consistent with the app's existing `max-w-*xl` scale (the widest other pages already use is
   `max-w-6xl`) rather than an arbitrary pixel value or `max-w-none`.
2. **Mobile date input truncation:** the controls row (Date / Type filter / Grid-List toggle) was
   `flex flex-wrap items-center gap-4` — all three groups competed for space on narrow viewports,
   squeezing the native date input (confirmed via live screenshot showing truncated
   "08/07/2C"). Fixed with the same mobile-stacking pattern already proven for `ListRow` earlier
   this phase: `flex-col` (stacked, full width) below 640px, `sm:flex-row` inline at 640px+.
3. **Sticky column visual overlay on horizontal scroll:** the sticky facility-name `<td>` used
   `bg-inherit` while the header's sticky `<th>` correctly used an explicit `bg-background`.
   `bg-inherit` resolves to the row's own semi-transparent `even:bg-muted/30` striping color,
   which is NOT fully opaque — confirmed via live screenshot showing facility names visually
   doubled with scrolled time-cell content bleeding through underneath during horizontal scroll.
   Fixed by matching the header's `bg-background` (fully opaque) on the sticky body cell too.
4. **Tooltip trigger area smaller than the visible box (List view only — Grid view's `SlotCell`
   was verified to already have styling and event handlers on the same element, so it needed no
   change):** `ListBookingRow` had its background/highlight styling on the outer `<div>` but the
   hover/focus/tooltip event handlers, `tabIndex`, and `aria-describedby` only on the inner
   time-text `<span>` — so hovering the "Confirmed"/"Cancelled" label or empty space in the row
   did nothing (confirmed via live screenshot: only the exact time digits triggered the tooltip).
   Fixed by moving the trigger wiring to the outer `<div>` so the entire visible box is
   interactive. `ResidentTooltip`'s `absolute`/`bottom-full`/`left-1/2` positioning already
   resolved against that same outer `<div>` (the nearest `position: relative` ancestor) before
   this fix too, so no positioning changes were needed — verified by RED/GREEN test.

**Scope:** `TenantDailyOverview.tsx` and its test file only. No other tenant-admin page's
`max-w-5xl` was touched; Grid view's `SlotCell` was left unchanged (verified correct); booking
date range/min-max logic was not touched (explicitly out of scope).

### feat: Daily Booking Overview for tenant-admins (July 2026)

**What:** New admin-only page (`/tenant/overview`) showing every facility for a chosen tenant on
a chosen date, alphabetically sorted, with all confirmed and cancelled bookings for that date —
each booking annotated with the resident's display name and email. Date picker allows any date,
including the past, for dispute resolution ("who was here yesterday"). A facility-type filter
narrows which facilities render. Grid view (facilities × time-slot columns, horizontal scroll)
is the default at viewport ≥640px; List view (one section per facility) is default below that;
a manual toggle overrides either default at any width. Cancelled bookings render with a distinct
muted/strikethrough treatment rather than being hidden, so admins can see cancellation activity.
Every booked/cancelled slot exposes the resident's name and email via a tooltip triggered by
both mouse hover and keyboard focus (`aria-describedby` wired for screen readers) — this is
genuinely new, admin-only data; the resident-facing `FacilityAvailability` page deliberately
never exposes other residents' identities, so this view could not reuse its data path.

Grid also shows full slot **capacity**, not just booked times: every valid slot for the date —
available, confirmed, or cancelled — renders as its own column, so admins can see open capacity
alongside activity, not just activity in isolation (this was the design mockup's intent; the
first pass only rendered columns for times something happened to be booked). Available slots
render as a distinct, non-interactive cell (no tooltip — nothing to show). List view is
deliberately unchanged and still enumerates bookings only, not open slots — per-slot enumeration
there would work against its purpose as the leaner, mobile-friendly view (a facility with 10 open
slots and 1 booking would otherwise produce 10 near-empty rows on a small screen).

**Backend:** `GET /api/v1/tenant/overview/daily?date=YYYY-MM-DD` (`daily_overview.py`,
`require_role("tenant_admin")`). New `BookingRepository.list_for_date()` queries all bookings
(confirmed and cancelled) for the tenant on a date via a single equality filter — no composite
index needed. For each unique resident uid appearing that day, one profile lookup is made
(N+1) to attach `display_name`/`email` — the same documented trade-off already accepted in
`repositories/base.py`'s `list_tenants()` (`admin_emails`), appropriate at current tenant scale
rather than building batch-fetch infrastructure for it. Facility ordering is sorted
alphabetically by name, scoped to this endpoint only — the existing facilities list elsewhere
in the app is intentionally left unordered pending a separate decision.

Each facility entry also carries a `slots` list: its full valid slot-start geometry for the date,
computed by reusing `services/availability.py`'s `compute_slots` (the same `weekly_schedule` +
`slot_duration_minutes` expansion the resident-facing availability endpoint uses) rather than
re-walking the same ranges independently. `compute_slots`' own resident-booking-eligibility
verdict (`bookable`/`reason`, `PAST`/`BEYOND_HORIZON`/`WINDOW_NOT_OPEN`) is discarded — it doesn't
apply to an admin browsing any date, including arbitrary history — and only its start/end
geometry is kept. Each slot's real status (`available`/`confirmed`/`cancelled`) is then determined
by cross-referencing that facility's own bookings for the date, which distinguishes confirmed from
cancelled, something `compute_slots`' plain booked-or-not set cannot. `bookings` (booking events
only) is unchanged and still what List reads from.

**Frontend:** `TenantDailyOverview.tsx` + `useDailyOverview` hook (`tenantAdminHooks.ts`),
linked from the tenant dashboard. Client-side alphabetical sort mirrors the backend guarantee.
Grid's time-axis is the union of every facility's full `slots` range for the date, not just times
where something is booked somewhere.

**Out of scope (explicitly rejected):** multi-day range/aggregate view; any change to the
resident-facing availability page or its data logic; any change to booking creation/cancellation
logic (this is a read-only view).

### fix(frontend): ListRow stacks on mobile instead of squeezing content into a fixed-width remainder (July 2026)

**Root cause:** PR #101 removed `truncate` from the facility name, which stopped text from being
cut off but exposed a deeper problem: `ListRow`'s outer wrapper was `flex items-center
justify-between gap-3` — always a single row, always squeezing the content `flex-1` area into
whatever width remained after the `shrink-0` action area. With 3 buttons (Edit / Clone / Remove)
on a narrow phone, the remaining text area was too narrow, causing names like "Table Tennis Court
- 1" to wrap one word per line.

**Fix:** `ListRow` now stacks content above actions on mobile (matching `TenantUsers.tsx`'s
already-correct inline pattern) and goes side-by-side only at the `sm:` breakpoint. The action
area loses its non-responsive `shrink-0` — it keeps `sm:shrink-0` so it stays fixed-width on
wider screens. Action buttons in all three consumer pages gain `flex-1 sm:flex-none` so they share
equal width on mobile and return to natural width at `sm+`.

**Scope:** Fixed at the shared-component level (`ListRow.tsx`) so all three consumers benefit, not
just TenantFacilities: `TenantFacilities.tsx`, `TenantList.tsx` (admin), and `MyBookings.tsx`.

### fix: Booking Policies form now loads actual saved values (July 2026)

**Bug:** `TenantPolicies.tsx` initialized its four form fields with hardcoded literals
(`useState(14)`, `useState("06:00")`, `useState(1)`, `useState(2)`) and had no fetch-on-mount
at all — no `useQuery`, no `useEffect`. The `PATCH /tenant/policies` route worked correctly
(confirmed via direct Firestore inspection: `booking_horizon_days: 2`, `cancellation_buffer_hours: 1`,
`max_slots_per_user_per_sport_per_day: 1` were genuinely persisted), but there was no
`GET /tenant/policies` route in the backend to read them back, and no call in the frontend to
fetch them even if the route had existed. The form always displayed its defaults regardless of
what the tenant had saved.

**Fix:**
- Added `GET /tenant/policies` to `tenant_config.py` (same `require_role("tenant_admin")` guard
  as the PATCH route; reads the tenant's `policies` dict from Firestore, returning `{}` when no
  policies subdocument exists — matching the convention used by the PATCH route itself).
- Added `usePolicies()` query hook and `Policies` interface to `tenantAdminHooks.ts`.
- Updated `useUpdatePolicies()` to invalidate the `["tenant", "policies"]` query key on success,
  so the form reflects the saved state immediately after a PATCH.
- `TenantPolicies.tsx` now fetches current values on mount and populates form state via
  `useEffect`, mirroring `TenantBranding.tsx`'s existing working pattern exactly.

**Tests:**
- New regression test asserts that the form shows fetched values (`horizon=2, max=1`) rather than
  the hardcoded defaults (`horizon=14, max=2`) — the exact scenario that was broken.
- New test confirms empty server response (`{}`) keeps form defaults (correct fallback behavior).
- 3 new backend tests cover `GET /tenant/policies`: saved values returned correctly, empty dict
  when no policies saved, residents forbidden (403).

### Phase 13.5 — Search, Tenant-Admin Visibility, Mobile Polish & Testing (July 2026)

**Item 1 — Client-side search (TenantUsers.tsx, TenantList.tsx):**
Added text-filter inputs to both pages. Filter is client-side only — it operates on the
current loaded page of results, not a server-side query. This limitation is explicitly
documented in source comments; pagination + full-text search is out of scope for v1.

**Item 2 — Tenant-admin visibility (`PlatformRepository.list_tenants`):**
`list_tenants` now queries each tenant's `users` subcollection for `role=="tenant_admin"` and
returns `admin_emails: string[]` per tenant. N+1 pattern accepted at current scale (~3-4
tenants). The field is optional (`admin_emails?: string[]` in `Tenant` interface) so all
existing callers remain backward-compatible without changes.

**Item 3 — Facility mobile layout (`TenantFacilities.tsx`):**
Removed `truncate` from the facility name `<p>` so long names wrap naturally on narrow
viewports. Changed the action button row from `flex items-center gap-2` to
`flex flex-wrap items-center gap-2` so buttons wrap instead of overflowing on small screens.

**Item 4 — Build-identifier endpoint:**
`BUILD_ID` env var injected via `${{ github.sha }}` in `deploy.yml`; passed through
`--set-env-vars` in `scripts/deploy_cloud_run.sh`. New `/version` route in `health.py`
exposes `{"build_id": "<sha-or-dev>"}` — kept separate from `/health` (liveness) and
`/readyz` (readiness) per ADR-0006.

**Item 5 — Shared TempPasswordModal component:**
Single `TempPasswordModal` component (Dialog + CredentialDisplay) replaces inline
credential display in `TenantUsers.tsx` (newCred + resetCred) and the full-page `created`
block in `CreateUser.tsx`. Radix UI Dialog portals to document.body — existing tests that
check modal content via `document.body` continue to pass unmodified.

**Item 6 — household_id: CONFIRMED WORKING AS DESIGNED. NOT TOUCHED.**
`household_id` is derived from `flat_number` when omitted and stored correctly in Firestore.
The ADR-compliant behavior was verified; no code change was made.

**Item 7 — Bulk import test coverage (`test_bulk_create_users.py`):**
New test file covering the ADMIN bulk endpoint at
`/api/v1/admin/tenants/{tenant_id}/users/bulk` — previously had ZERO tests.
6 scenarios: all-rows-succeed, partial failure (reason uses `exc.message` not `exc.code`),
empty rows (returns `{results: []}`), row missing flat_number (per-row fail, batch continues),
over-500-rows (422), non-admin caller (403).

**Item 8 — Styled CSV file input (`TenantUsers.tsx`):**
Native `<input type="file">` moved to visually hidden (`sr-only`); a styled `<Button>` now
triggers it via `useRef`. The `accept=".csv,text/csv"` attribute and `onChange` handler are
preserved. The hidden input remains in the DOM so
`document.querySelector('input[type="file"]')` in tests continues to work.

### Phase 13.8 — Force Token Refresh + Claims-Error Recovery UI (July 2026)

**Bug confirmed via live reproduction:** A fresh `signInWithEmailAndPassword` call can return a
valid Firebase ID token that is stale with respect to custom claims (`tenant_id`, `tenant_slug`,
`role`) — Firebase's documented behavior is that `set_custom_user_claims()` takes effect on the
NEXT token refresh, not immediately. When the app's first API call (`GET /api/v1/users/me`) fires
with this stale token, the backend correctly rejects it with 401 `AUTH_INVALID_TOKEN` /
"Token missing provisioned claims". Previously the app had no error-recovery path: the fetch
failure was silently caught and the app hung on a blank screen with no retry mechanism.

**Scope boundary (explicit):** This fix addresses ONLY the stale-token-after-fresh-sign-in case.
It does NOT fix the separate, confirmed-different `Content-Length: 0` CDN/LB blank-screen case
(tracked in sub-phase 13.6) — that failure produces zero bytes of HTML on the wire, so no
client-side fix is possible for it (there is no page loaded, no JS running).

**Fix 1 — Force token refresh after sign-in (`AuthContext.tsx`):**
`signIn` and `signInWithGoogle` now call `await auth.currentUser?.getIdToken(true)` after the
Firebase auth call succeeds, forcing a token refresh that picks up current custom claims before
any downstream API call is made. NOT added to `onIdTokenChanged` (wasteful; only the initial
post-sign-in moment needs forcing).

**Fix 2 — Defense-in-depth: claims-error recovery UI (`AuthContext.tsx` + `api.ts` + new `ClaimsErrorFallback.tsx`):**
- `api.ts`: `setClaimsErrorHandler` callback mechanism. When `apiFetch` detects specifically
  `401 + AUTH_INVALID_TOKEN + "Token missing provisioned claims"`, it signals the handler.
  `AUTH_MISSING_TOKEN` and "Token verification failed" are different failure modes — not wired.
- `AuthContext.tsx`: registers handler on mount; `claimsError: boolean` state +
  `retryClaimsRefresh()` in `AuthState`. When `claimsError` is true, renders `ClaimsErrorFallback`
  instead of children. Retry forces `getIdToken(true)`, invalidates all React Query cache, clears.
- `ClaimsErrorFallback.tsx` (new): full-page fallback with message and Retry button.

**Tests:** 35 new tests across 3 files. Full suite: 306 tests, 41 files, all passed.

### Phase 13.7 — Apex Sign-In Redirect + Cross-Tenant Login Correction (July 2026)

**13.7a (infra, already shipped):** DNS A record for the bare apex `slotsense.chandraailabs.com`
added (Namecheap), LB host_rule updated to include it alongside the wildcard, TLS cert already
covered both hostnames as SANs. `curl -sI https://slotsense.chandraailabs.com/` confirmed 200.
Backend tenant resolution (`_slug_from_host`, `auth/dependency.py`) already handles the apex
correctly by design — returns `None` (trust JWT, ADR-0007). No backend change needed or made.

**Bugs closed (both collapse into one fix):**
1. A user signing in at the bare apex (`slotsense.chandraailabs.com`) landed on `/tenant` with
   default branding — functionally correct (JWT enforces tenant scoping) but wrong URL, no tenant
   branding, unshareable.
2. A user signing in on a DIFFERENT tenant's subdomain (e.g. ddsociety admin signing in on rvrg's
   domain) succeeded — Firebase Auth validates credentials regardless of origin — with incorrect
   host context.

**Unified fix — `frontend/src/auth/AuthContext.tsx`:**
- New exported `slugFromHost(hostname: string): string | null` helper (mirrors the backend's
  `_slug_from_host` three-way logic): exact apex → `""`, `{x}.apex` → `"{x}"`, everything else
  (localhost, `*.web.app`, `*.run.app`, unrecognized) → `null` (skip check, preserve local dev).
- In `onIdTokenChanged`, after `setClaims`: if role is `platform_admin` OR `slugFromHost` returns
  `null`, skip entirely. Otherwise, if host-derived slug ≠ `claims.tenant_slug`: sign out
  (`fbSignOut`) then hard-navigate (`window.location.href`) to
  `https://{tenant_slug}.slotsense.chandraailabs.com/signin?redirected=1`.

**`frontend/src/pages/SignIn.tsx`:** If `?redirected=1` is present in the URL (via
`useSearchParams`), shows a small informational banner:
"You've been redirected to your community's sign-in page — please sign in again."

**Known, deliberately unaddressed gap:** A `platform_admin` landing on a tenant subdomain is not
corrected by this fix (they have no `tenant_slug` to redirect toward). Not reported as a bug;
separate future concern.

**Tests:** 14 new tests in `AuthContext.test.tsx` — `slugFromHost` unit tests (6 cases) +
`onIdTokenChanged` scenario tests: apex+tenant_admin redirect, apex+resident redirect, matching
subdomain no-redirect, wrong-subdomain redirect, platform_admin on apex no-redirect, localhost
no-redirect (dev-safety), `*.web.app` no-redirect, null user no-error. 3 new tests in
`SignIn.test.tsx` — banner present/absent/wrong-param-value. Full suite: 293 tests, 39 files.

### Phase 13.4 — Tenant-Level Permanent Delete (July 2026)

**HIGHEST-RISK PR in Phase 13 — requires Coordinator line-by-line review before merge.**

Platform-admin-only `DELETE /admin/tenants/{tenant_id}/permanent` route that irreversibly
destroys an entire tenant and all its data. Guarded by `require_platform_admin`; returns 403
for any non-platform-admin token.

**Deletion order (correctness-critical):**
1. Confirm tenant exists (404 if not) and capture slug/display_name BEFORE any destructive step.
2. Enumerate all user UIDs from `tenants/{id}/users` subcollection — MUST happen before step 3
   (subcollection is gone after recursive_delete).
3. `client.recursive_delete(tenant_ref)` — wipes entire Firestore subtree atomically.
4. Delete each Firebase Auth user; `UserNotFoundError` is tolerated per the Phase 13.3 pattern
   (already-absent users counted in `auth_users_already_absent`, not treated as errors).
5. Write no-PII audit stub to new top-level `platform_deletion_log` collection — deliberately
   OUTSIDE the tenant's subtree so the record survives the recursive delete that destroyed it.

**New files:**
- `backend/src/sport_slot/repositories/platform_deletion_log.py` — module-level `write_deletion_log()`
  following `password_reset.py`'s top-level collection pattern
- `backend/src/sport_slot/services/tenants.py` — `delete_tenant_permanently()` service function
- `backend/tests/test_tenant_permanent_delete.py` — 4 two-sided tests: (a) 403 for tenant-admin,
  (b) full cascade with counts, (c) UserNotFoundError tolerance, (d) 404 for missing tenant

**Frontend:**
- `adminHooks.ts`: `useDeleteTenantPermanently()` hook (mutate by tenant_id, invalidates tenant list)
- `TenantList.tsx`: Delete button per row — opens `ConfirmDialog` with `confirmationPhrase={t.slug}`
  so the operator must type the specific tenant's slug before the Confirm button enables
- 5 Vitest tests (d) covering: button renders, dialog opens with correct phrase, disabled for
  wrong slug, enabled for exact match, mutate called with correct tenant_id

**Phase 15 invoice carve-out:** documented inline — when Phase 15 ships, this function must skip
invoice records from the recursive delete per ADR-0034's carve-out.

### Phase 13.3 — Facility Delete + Deactivate Hiding + Delete Hardening (July 2026)

Root cause driving all three changes: the deactivate-only path has no corresponding
Reactivate screen anywhere in the product. This creates unrecoverable "stuck" entities —
confirmed this session via a real incident where a previously-deactivated resident's
Firebase Auth account blocked re-registration of their email address, with no fix available
except manual Firebase CLI intervention. Until Deactivate+Reactivate is properly designed
and built (deferred, separate future phase), prefer permanent delete over deactivate-without-
reactivate project-wide.

**1. Facilities: `DELETE /tenant/facilities/{id}` now permanently deletes the Firestore doc**
(previously: set `active: False`). The frontend button is already labeled "Remove" — no
button label change needed. The cancel+notify+audit pipeline is unchanged in substance:
- `cancel_booking(force=True, cancelled_by_override="facility_deleted")` for each confirmed
  future booking — reason string renamed from `"facility_deactivated"` to `"facility_deleted"`
- Audit event_type renamed `facility.deactivated` → `facility.deleted`
- `ref.delete()` replaces `ref.update({"active": False})` (now runs AFTER cancellations)
- Response body changed: `{"id", "status": "deleted", "bookings_cancelled": N}` — no `active` key

**2. `render_booking_cancelled` reason-string check updated** (`notifications/email/templates.py`):
`if reason == "facility_deactivated":` → `if reason == "facility_deleted":`.
Old string no longer triggers the "This facility is no longer available." notice (verified by
`test_booking_cancelled_old_deactivated_reason_does_not_show_notice`).

**3. Users page: "Deactivate" button removed from the UI** (`TenantUsers.tsx`).
Backend `deactivate_user` route, service method, and all existing backend tests are completely
unchanged and still pass. The `useDeactivateTenantUser` hook definition in `tenantAdminHooks.ts`
is also unchanged. Only the UI trigger (button + ConfirmDialog + associated state) is removed
from TenantUsers.tsx, pending a proper Deactivate+Reactivate redesign later.

**4. `delete_user_permanently` now tolerates an already-absent Firebase Auth user**
(`services/provisioning.py`): previously `fb_auth.delete_user(target_uid)` raising
`firebase_admin.auth.UserNotFoundError` would abort the whole deletion, leaving Firestore
data (bookings, profile) un-cleaned. Now: catches only `fb_auth.UserNotFoundError`, logs
a structured warning (`delete_user_permanently_auth_already_absent`), and continues to the
audit stub and profile doc deletion. Other exception types from Firebase Auth still abort
and surface as errors.

**Tests:** 397 passed (90.82% coverage, gate ≥ 90%). Two-sided (RED/GREEN) tests:
- `(a)` `test_delete_facility_permanently_removes_document` — `ref.delete()` called, no
  `ref.update()`, response has `status="deleted"` and no `active` key
- `(a)` `test_delete_facility_cancels_future_bookings_and_writes_audit` — new reason string,
  new event_type, no `active` in response
- `(b)` `test_booking_cancelled_facility_deleted_shows_notice` / `..._old_deactivated_reason_does_not_show_notice` — exact rename verified
- `(c-harden)` `test_delete_user_permanently_auth_user_not_found_completes_cleanup` — 200
  returned, bookings+profile cleaned up, audit written despite UserNotFoundError
- `(d)` TenantUsers: Deactivate button absent, Delete button present (both assertions)
- Existing user-deactivate backend tests: 4 passed unmodified

### Phase 13.2 — Permanent Delete for Residents/Tenant-Admins (July 2026)

Direct permanent delete for tenant-admin use: irreversible removal of a user's
Firebase Auth account, all booking documents, and profile document (ADR-0034 §2).

**New `DELETE /api/v1/tenant/users/{uid}/permanent` route** (`api/v1/tenant_config.py`):
Tenant-admin only. Self-deletion is forbidden (returns `403 SELF_DELETION_FORBIDDEN`).
Deletion order: (1) all booking docs for the user (`bookings.where("uid", "==", target_uid)`),
(2) Firebase Auth user (`fb_auth.delete_user`), (3) no-PII audit stub
(`user.deleted` with `{target_uid, bookings_deleted}`, no email/name), (4) profile doc.
Returns `{"uid", "status": "deleted", "bookings_deleted": N}`.
Phase 15 invoice carve-out: explicit code comment added; no invoice collection exists yet
and no speculative deletion logic was added.

**New `SELF_DELETION_FORBIDDEN` error code** (`api/error_codes.py`):
Added alongside `SELF_DEACTIVATION_FORBIDDEN`. Maps to HTTP 403 from the existing
`_provisioning_error` helper in `tenant_config.py`.

**`ConfirmDialog` gains optional `confirmationPhrase?: string` prop** (`components/ConfirmDialog.tsx`):
When set, renders a text input below the body; the confirm button is disabled until the
user types the phrase exactly. Fully backward-compatible — existing callers that omit the
prop behave identically to before (no input rendered, button enabled when `busy=false`).

**New Delete button in `TenantUsers.tsx`:**
Separate from the existing Deactivate button (existing button unchanged). Calls
`useDeleteTenantUserPermanently()` (`hooks/tenantAdminHooks.ts`). Opens ConfirmDialog with
`confirmationPhrase="DELETE"`, requiring the user to type "DELETE" before the confirm button
becomes enabled. Existing deactivate route and button completely unmodified.

**Tests:** 395 passed (90.80% coverage, gate ≥90%). Two-sided (RED/GREEN) tests:
- Backend (test_tenant_config.py):
  - `test_delete_tenant_user_permanently_self_delete_returns_403` — 403 + nothing deleted
  - `test_delete_tenant_user_permanently_deletes_bookings_auth_and_profile` — full deletion chain verified + audit PII check
  - `test_delete_tenant_user_permanently_404_when_user_not_found` — 404 + no side effects
- Frontend ConfirmDialog (ConfirmDialog.test.tsx):
  - `(d)` confirmationPhrase renders textbox, disables until exact match, re-disables on clear
  - `(e)` backward-compat: no confirmationPhrase → confirm enabled (existing callers unaffected)
- Frontend TenantUsers (TenantUsers.test.tsx):
  - Delete button rendered alongside Deactivate
  - Delete button opens ConfirmDialog with textbox
  - Confirm fires mutation only after typing DELETE exactly
  - Deactivate button regression guard (present and enabled)

### Phase 13.1 — Deactivation Audit + Cancellation Notification (July 2026)

Three related gaps in the deactivation and booking-cancellation area, all fixed together
because they share the same functional concern (what happens to bookings and audit trails
when a user or facility is deactivated):

**1. `deactivate_user` now writes a `user.deactivated` audit event (ADR-0011):**
`UserProvisioningService.deactivate_user` (`services/provisioning.py`) previously called
`_cancel_future_bookings` and returned without writing any audit event, unlike its siblings
`create_user` (writes `user_provisioned`) and `reset_password` (writes `user.password_reset`).
Fix: `AuditRepository.write_event(event_type="user.deactivated", ..., details={"target_uid": ...})`
is now called after `_cancel_future_bookings` on every successful deactivation.

**2. `cancel_booking` now sends a best-effort `booking_cancelled` notification on every
cancellation (ADR-0019), plus gains `force` and `cancelled_by_override` params:**
`cancel_booking` (`services/bookings.py`) previously wrote an audit event but sent no email
to the booking owner, for any cancellation path. This gap affects all cancellations (resident
self-cancel, admin cancel, and the facility-deactivation path). New params:
- `force: bool = False` — when `True`, skips the cancellation-buffer check (which exists to
  protect residents from self-cancelling too late, not to block system-triggered removals).
- `cancelled_by_override: str | None = None` — when set, replaces the computed `cancelled_by`
  value ("self" / "tenant_admin") in both the Firestore update and the audit event details.
  Also forwarded as `reason` in notification params.
Normal (non-force) calls behave identically to before except for the new notification.

**3. `deactivate_facility` now cancels affected future bookings, notifies residents, and
writes a `facility.deactivated` audit event (ADR-0034 §1):**
`deactivate_facility` (`api/v1/facilities.py`) previously only flipped `active: False`.
It now: queries all confirmed future bookings for the facility; calls
`cancel_booking(..., force=True, cancelled_by_override="facility_deactivated")` for each
(individual failures are logged and counted but do not abort the rest); writes a
`facility.deactivated` audit event with `{"facility_id": ..., "bookings_cancelled": N}`;
and returns `bookings_cancelled` in the HTTP response body. Residents receive a
`booking_cancelled` email with "This facility is no longer available." in the body when
the reason is `facility_deactivated`.

**New `booking_cancelled` email template** (`notifications/email/templates.py`):
`render_booking_cancelled` follows the same pattern as `render_booking_confirmed` (HTML-escaped,
`_HTML_WRAPPER`, `RenderedEmail` return). When `reason == "facility_deactivated"`, the body
includes "This facility is no longer available." — other reason codes are not shown to residents.
Registered in `_RENDERERS` in `api/internal/tasks.py`.

**Known gap explicitly NOT fixed here:** `_cancel_future_bookings` (the user-deactivation
path in `services/provisioning.py`) still cancels bookings by writing directly to Firestore
rather than calling `cancel_booking`, so it still bypasses the notification and `cancelled_by`
attribution logic. This gap is logged as a deliberately deferred item for a future sub-phase.

**Tests:** 392 passed (90.65% coverage, gate ≥90%). Individual two-sided (RED/GREEN) tests:
- `test_deactivate_user_writes_user_deactivated_audit_event` (test_admin_provisioning.py)
- `test_cancel_booking_force_bypasses_cancellation_buffer` (test_cancel_booking_svc.py)
- `test_cancel_booking_enqueues_booking_cancelled_notification` (test_cancel_booking_svc.py)
- `test_cancel_booking_cancelled_by_override_in_update_and_audit` (test_cancel_booking_svc.py)
- `test_deactivate_facility_cancels_future_bookings_and_writes_audit` (test_tenant_facilities.py)
No failed booking IDs during deactivate_facility test scenario (query stream returned all
expected bookings; cancel_booking mocked — no partial-failure path exercised).

### Phase 13.0 — Deactivate Validation (July 2026)

**Validation scope:** Deactivate button behavior for tenant users and facilities in the
tenant-admin UI. Reproduction performed via backend unit tests (GCP credentials expired
during session; test-based two-sided guard used per protocol §3.3).

**User deactivation — bug found and fixed:**
Root cause: `UserProvisioningService.deactivate_user` (`backend/src/sport_slot/services/provisioning.py`)
wrote `{"status": "inactive", "deactivated_at": ...}` to Firestore but never set
`active: False`. The frontend user list filter (`TenantUsers.tsx` line 106) is
`u.active !== false`. Since the `active` field was absent from the user profile
(neither at creation nor at deactivation), deactivated users always passed the filter and
remained visible in the "Active users" list after a successful deactivation and
query-invalidation re-fetch.

Fix: added `"active": False` to the `repo.update` call in `deactivate_user`. Regression
test `test_deactivate_tenant_user_sets_active_false` (new, in `test_tenant_config.py`)
verified RED before fix (update dict lacked `active` key), GREEN after fix. Full backend
suite: 379 passed (91% coverage). Frontend suite: 261 passed.

**Facility deactivation — works as designed (known gap confirmed):**
`deactivate_facility` (`backend/src/sport_slot/api/v1/facilities.py`) sets `active: False`
in Firestore. The frontend filter (`TenantFacilities.tsx` line 143) is `f.active`, a
truthy check. The facility correctly disappears from the list after deactivation. The
button works end-to-end for the flag flip.

**Known gap (NOT fixed here, scoped to Phase 13 main sub-phase):** Facility deactivation
does not cancel future bookings, does not notify residents, and does not write an audit
event. This matches the intent in CONTEXT and ADR-0034 scope. No change made to this
behaviour in 13.0.

### Phase 8b — Production Networking: rollup (July 2026)

Phase 8b replaced Firebase Hosting's implicit infrastructure with an explicit,
Terraform-managed GCP production networking stack. 12 PRs (#80–#91), 5 new Terraform
files, 3 new ADRs (0031–0033), and 384 Terraform lines net-added. Backend test suite
remained green (378 tests) throughout.

**What shipped:**
- Global External HTTPS Load Balancer at `*.slotsense.chandraailabs.com` — API via Cloud
  Run Serverless NEG, frontend via GCS backend bucket with Cloud CDN
  (`USE_ORIGIN_HEADERS`)
- Wildcard TLS via Certificate Manager + DNS authorization (Certificate Manager required;
  classic managed SSL certs reject wildcards entirely — ADR-0031)
- HTTP → HTTPS 301 redirect on port 80
- SPA 404 catch-all via `default_custom_error_response_policy` (replicates Firebase
  Hosting `source: "**"` rewrite)
- Root-path rewrite (`"/"` → `"/index.html"`) to prevent GCS bucket-listing XML on bare
  root requests
- Cloud Armor WAF in preview/log-only mode: `CLOUD_ARMOR` policy on API backend (SQLi +
  XSS CRS 4.22 sensitivity 1); `CLOUD_ARMOR_EDGE` policy on frontend bucket (default-allow
  only — preconfigured WAF expressions unsupported on edge type) — ADR-0032
- Cloud Run ingress restricted to `internal-and-cloud-load-balancing`; codified in deploy
  script (`--ingress` defaults to `all` if omitted) — ADR-0033
- Email deep-links (`reset_continue_url`, `welcome_login_url`) updated from
  `sport-slot-dev.web.app` to `slotsense.chandraailabs.com`

**7 issues caught and resolved:** wildcard TLS resource type mismatch (PR #81),
`evaluatePreconfiguredExpr` wrong function name (PR #87), `preview=true` rejected on
default rule (PR #88), WAF expressions unsupported on CLOUD_ARMOR_EDGE (PR #89),
`CACHE_ALL_STATIC` silently overriding SPA `Cache-Control` headers (PR #84), Firebase
Hosting ingress incompatibility caught via pre-implementation investigation (PR #90),
GCS root-path listing returning XML bypassing the 404 error policy (PR #91).

Full details: [`docs/retrospectives/phase-8b.md`](docs/retrospectives/phase-8b.md),
[`docs/reports/phase-8b-engineering-report.md`](docs/reports/phase-8b-engineering-report.md)

---

### Root Path Fix — rewrite / to /index.html before reaching GCS (July 2026)

**Bug:** `https://rvrg.slotsense.chandraailabs.com/` (bare root) returned a raw GCS
bucket-listing XML response instead of `index.html`. Root cause: GCS treats the empty root
key as a valid list-bucket operation (`allUsers` has `storage.objects.list` via
`objectViewer`), returning HTTP 200 with XML — the existing 404→index.html error policy
never engaged because there was no 404 to intercept.

**Fix:** Added a `path_rule` for `paths = ["/"]` in `terraform/load_balancer_routing.tf`
that rewrites the path to `/index.html` before the request reaches GCS (`route_action {
url_rewrite { path_prefix_rewrite = "/index.html" } }`). GCS now always receives a request
for a real named object. Verified against provider 6.50.0 schema; plan shows 0 add, 1
change, 0 destroy. NOT YET APPLIED.

### Phase 8b.6 — Cloud Run ingress restriction + web.app path deprecation (July 2026)

Closes the X-Forwarded-Host spoofing surface (ADR-0012 open VERIFY-ITEM) by restricting
Cloud Run ingress to `internal-and-cloud-load-balancing`. Firebase Hosting's
`sport-slot-dev.web.app/api/**` rewrite path becomes non-functional — accepted since this
is DEV with no real tenant traffic on that path. Cloud Tasks confirmed compatible
(explicitly in Google's internal-traffic list, same project, uses run.app URL).

- **`backend/src/sport_slot/config.py`** (lines 32–33): `reset_continue_url` and
  `welcome_login_url` updated from `sport-slot-dev.web.app` to `slotsense.chandraailabs.com`.
  Public auth routes (token carries user context; URL is purely a SPA landing page).
- **`scripts/deploy_cloud_run.sh`** (line 66): `--ingress=internal-and-cloud-load-balancing`
  added explicitly. Required because `gcloud run deploy --ingress` defaults to `all` — omitting
  it would silently reset the restriction on every CI deploy.
- **`docs/adr/0033-dev-web-app-path-deprecated.md`** (NEW): Documents Firebase Hosting
  incompatibility (confirmed), Cloud Tasks compatibility (confirmed), deploy persistence
  issue, and future production caution.
- **Coordinator live command** (run manually after PR merges):
  `gcloud run services update sport-slot-api --region asia-south1 --project sport-slot-dev --ingress=internal-and-cloud-load-balancing`

### Phase 8b.5 correction 3 — remove WAF rules from edge policy (July 2026)

`CLOUD_ARMOR_EDGE` policies do not support preconfigured WAF expressions at all
(`evaluatePreconfiguredWaf` is only valid on `CLOUD_ARMOR` type — confirmed via API error
on apply). Removed SQLi (priority 1000) and XSS (priority 2000) rule blocks entirely from
`google_compute_security_policy.frontend_edge`. Policy now contains only the mandatory
default allow rule. The `api` (`CLOUD_ARMOR`) policy is unaffected and already applied
successfully. Custom CEL-based edge rules deferred as deliberate future addition. NOT YET
APPLIED.

### Phase 8b.5 correction 2 — remove preview from default rule (July 2026)

GCP rejects `preview = true` on the mandatory default rule (priority 2147483647) with:
"Cannot preview the default rule". Removed `preview = true` from the default allow rule
in both `google_compute_security_policy.api` and `.frontend_edge` — no behavior change,
allow rules are non-blocking regardless. SQLi/XSS deny rules retain `preview = true`
unchanged. NOT YET APPLIED.

### Phase 8b.5 correction — evaluatePreconfiguredWaf (July 2026)

`evaluatePreconfiguredExpr` does not accept a sensitivity map argument (API error:
candidates `(string),(string, list(string))`). Corrected to `evaluatePreconfiguredWaf`,
the proper function for sensitivity-level control. 4 occurrences changed in
`terraform/cloud_armor.tf` — no other change. NOT YET APPLIED.

### Phase 8b.5 — Cloud Armor WAF, Preview Mode (July 2026)

Adds L7 WAF inspection via two Cloud Armor policies (log-only, non-blocking). Base L3/L4
DDoS protection already provided by the Global HTTPS LB remains unchanged.

- **`terraform/cloud_armor.tf`** (NEW): Two `google_compute_security_policy` resources —
  `slotsense-api-armor` (type `CLOUD_ARMOR`) and `slotsense-frontend-edge-armor`
  (type `CLOUD_ARMOR_EDGE`). Both carry `sqli-v422-stable` (priority 1000) and
  `xss-v422-stable` (priority 2000) at CRS 4.22 sensitivity level 1, all rules with
  `preview = true`. Default rule at priority 2147483647 is `allow` — no default-deny.
- **`terraform/load_balancer_backends.tf`**: `security_policy` attribute added to
  `google_compute_backend_service.api`; `edge_security_policy` attribute added to
  `google_compute_backend_bucket.frontend`. No other attributes changed.
- **`docs/adr/0032-cloud-armor-preview-mode.md`** (NEW): Documents two-policy design,
  preview-mode rationale, CRS 4.22 selection, DDoS clarification, and explicit deferral
  of rate limiting and Adaptive Protection.
- Rate limiting deferred — requires real booking-window traffic baselines.
- Adaptive Protection deferred — requires Cloud Armor Enterprise subscription decision.
- **NOT YET APPLIED** — `terraform apply` is a manual coordinator step.

### Phase 8b.4 — App Domain Config: sportbook → slotsense.chandraailabs.com (backend + frontend, July 2026)

Renames every forward-looking config and test reference from the old `sportbook.chandraailabs.com`
naming to `slotsense.chandraailabs.com`, matching Phase 8b's LB target domain. Both the code
default AND the deploy-time env var override are updated so neither can silently keep the old
value after the other is changed.

- **`backend/src/sport_slot/config.py`** (lines 17–18): `base_domain` default changed to
  `slotsense.chandraailabs.com`; `admin_host` default changed to
  `admin.slotsense.chandraailabs.com`.
- **`scripts/deploy_cloud_run.sh`** (line 68): `SPORTSLOT_BASE_DOMAIN` and
  `SPORTSLOT_ADMIN_HOST` in the `--set-env-vars` flag updated to match.
- **`backend/.env.example`** (lines 4–5): template file updated; developers copying this to
  `.env` will get the correct domain out of the box.
- **Backend test fixtures** (10 files): all `"*.sportbook.chandraailabs.com"` host constants
  updated to `"*.slotsense.chandraailabs.com"` in `test_auth.py`, `test_bookings.py`,
  `test_agent_booking.py`, `test_tenant_facilities.py`, `test_cancellation.py`,
  `test_availability_endpoint.py`, `test_admin_provisioning.py`, `test_tenant_config.py`,
  `test_users_me.py`, `test_facilities_and_policy.py`. Assertion logic unchanged; only
  fixture values updated.
- **`frontend/src/lib/tenant.ts`** (line 1): `BASE_DOMAIN` constant updated. This is
  functional code — the slug parser uses this to recognize `{slug}.slotsense.chandraailabs.com`
  subdomains; without this change the frontend would fail to extract the tenant slug from
  the new LB-served subdomain URLs.
- **`frontend/src/lib/tenant.test.ts`** (lines 6, 29): both subdomain test assertions
  updated to `demo.slotsense.chandraailabs.com`.
- **Deliberately NOT changed**: `backend/scripts/reset_superadmin.py` and
  `backend/scripts/seed_platform_admin.py` — these reference `admin@sportbook.chandraailabs.com`
  as an email address of a real, sole platform-admin account in Firestore/Firebase Auth;
  changing the script default without migrating that account would desync the script from
  reality (coordinator decision, Phase 8b.4).
- **ADR/docs files**: not changed — historical records preserve the original domain name
  as written at decision time.
- All gates green: backend **378 passed** (unchanged), frontend `tsc` clean, lint 0 errors,
  **261 tests passed**.

### Phase 8b.2b — CDN Origin Headers + GCS Sync (infra + ci, July 2026)

Two changes closing the loop between the Phase 8b.2 LB backend and live frontend delivery.

**Terraform (`terraform/load_balancer_backends.tf`):**
- `google_compute_backend_bucket.frontend`: switched CDN `cache_mode` from
  `CACHE_ALL_STATIC` (the provider default) to `USE_ORIGIN_HEADERS`. In
  `CACHE_ALL_STATIC` mode Cloud CDN ignores `Cache-Control: no-cache` from GCS object
  metadata and caches with `defaultTtl=3600s` instead — a stale PWA service worker
  (`sw.js`) could be served for up to an hour after deploy. `USE_ORIGIN_HEADERS` makes
  Cloud CDN honor the headers set at upload time: `no-cache` for `index.html`, `sw.js`
  etc. (revalidated on every request), `max-age=31536000,immutable` for hashed assets.
- `terraform plan` confirmed: **0 to add, 1 to change, 0 to destroy** (only this bucket's
  `cdn_policy.cache_mode`). **NOT YET APPLIED** — requires `make tf-apply-dev`.

**CI (`.github/workflows/deploy.yml`):**
- Added two new steps at the end of the `deploy` job (after existing step 9, the Firebase
  Hosting deploy) — all existing steps are unmodified:
  - **Step 10**: `Re-authenticate to Google Cloud (WIF, keyless — GCS sync)` — direct WIF,
    no SA impersonation. Required because step 8 (Mint Firebase access token) overwrites
    ADC to `sa-firebase-admin`, which has no GCS write permission. Re-auth restores the
    direct WIF principal, which already holds `roles/storage.admin` project-wide
    (`wif_iam.tf:61-65`).
  - **Step 11**: `Sync frontend dist to GCS (sport-slot-dev-frontend)` — syncs
    `frontend/dist/` (built in step 9) to `gs://sport-slot-dev-frontend` with per-file
    `Cache-Control` headers matching `firebase.json`'s existing 7 rules:
    - **`no-cache`**: `index.html`, `manifest.webmanifest`, `sw.js`, `registerSW.js`,
      `workbox-*.js`
    - **`public, max-age=31536000, immutable`**: `assets/*` (content-hashed files; old
      hashes are intentionally kept in GCS so users with a cached index.html can still
      fetch them)
    - **`public, max-age=86400`**: `favicon-32x32.png`, `pwa-192x192.png`,
      `pwa-512x512.png`, `pwa-maskable-512x512.png` (fixed filenames, not hash-versioned)
    - **Excluded**: `slotsense-icon-source.png` (raw source artifact, not a deployable
      asset)
- No new IAM grants needed — the CI WIF principal's existing project-level
  `roles/storage.admin` covers `sport-slot-dev-frontend`.
- CI change takes effect on next merge to main.

### Phase 8b.2 — LB Backend Infra + HTTP Redirect (infra, July 2026)

Full backend infrastructure for the Global External HTTPS Load Balancer: Cloud Run NEG +
backend service for the API; GCS bucket + backend bucket for the static frontend (with SPA
catch-all 404→200 fallback); URL map + HTTPS proxy + forwarding rule wiring the HTTPS path;
parallel HTTP→HTTPS redirect on port 80. **NOT YET APPLIED** — Coordinator must run
`make tf-apply-dev`. After apply the GCS bucket will be EMPTY (frontend CI sync is Phase
8b.2b); DNS A record for `*.slotsense.chandraailabs.com` still needed (Phase 8b.3).

- **`terraform/load_balancer_backends.tf`** (new file, 5 resources):
  - `google_storage_bucket.frontend` — `sport-slot-dev-frontend`, ASIA-SOUTH1, uniform
    bucket-level access enabled
  - `google_storage_bucket_iam_member.frontend_public_read` — `allUsers`
    `roles/storage.objectViewer` (deliberate: public static web assets, no PII)
  - `google_compute_backend_bucket.frontend` — `slotsense-frontend-bucket`, CDN enabled
  - `google_compute_region_network_endpoint_group.api_neg` — `slotsense-api-neg`, serverless
    NEG for Cloud Run service `sport-slot-api` in `asia-south1`
  - `google_compute_backend_service.api` — `slotsense-api-backend`, HTTPS, EXTERNAL_MANAGED,
    request logging enabled at 100% sample rate
- **`terraform/load_balancer_routing.tf`** (new file, 6 resources):
  - `google_compute_url_map.slotsense_https` — `slotsense-https-url-map`; host_rule for
    `*.slotsense.chandraailabs.com`; path_matcher routes `/api/*`, `/health`, `/readyz` to
    API backend, everything else to frontend bucket; `defaultCustomErrorResponsePolicy` at
    path_matcher level intercepts GCS 404s → serves `/index.html` with HTTP 200, replicating
    Firebase Hosting's SPA catch-all (GCS `NotFoundPage` returns 404 status — this policy
    is the correct GCP LB mechanism to override that)
  - `google_compute_target_https_proxy.slotsense` — `slotsense-https-proxy`; references the
    Phase 8b.1 Certificate Manager cert map via the required
    `//certificatemanager.googleapis.com/<map-id>` format
  - `google_compute_global_forwarding_rule.slotsense_https` — `slotsense-https-forwarding-rule`,
    port 443, `EXTERNAL_MANAGED`, references Phase 8b.1 static IP
  - `google_compute_url_map.slotsense_http_redirect` — `slotsense-http-redirect`;
    `default_url_redirect` with `https_redirect=true`, `strip_query=false`
  - `google_compute_target_http_proxy.slotsense_redirect` — `slotsense-http-proxy`
  - `google_compute_global_forwarding_rule.slotsense_http` — `slotsense-http-forwarding-rule`,
    port 80, same static IP as HTTPS rule
- `terraform plan` confirmed: **11 to add, 0 to change, 0 to destroy**; all Phase 8b.1
  resources show 0 changes.
- `terraform fmt` and `terraform validate` clean.

### Phase 8b.1 Correction — Certificate Manager for Wildcard Cert (infra, July 2026)

`google_compute_managed_ssl_certificate` does not support wildcard domains (GCP API
error: "Wildcard domains not supported" — hard platform limitation, not a config error).
Replaced with Google Cloud Certificate Manager, which supports wildcards via DNS
authorization. **NOT YET APPLIED** — Coordinator must run `make tf-apply-dev`, then add
the DNS authorization CNAME record at Namecheap (values available only after apply).

- **`certificatemanager.googleapis.com`** enabled via `gcloud services enable`, documented
  in `terraform/apis.tf` locals (count updated to 21).
- **`terraform/load_balancer_network.tf`**: removed `google_compute_managed_ssl_certificate`
  (never reached state — creation errored before an ID was returned, confirmed via
  `terraform state list`). Added 4 Certificate Manager resources:
  - `google_certificate_manager_dns_authorization.slotsense` (name: `slotsense-dns-auth`,
    domain: `slotsense.chandraailabs.com`) — generates the CNAME record Namecheap needs
  - `google_certificate_manager_certificate.slotsense_wildcard_cert` (name:
    `slotsense-wildcard-cert`, domains: apex + wildcard, linked to dns_authorization)
  - `google_certificate_manager_certificate_map.slotsense` (name: `slotsense-cert-map`)
  - `google_certificate_manager_certificate_map_entry.slotsense_wildcard` (PRIMARY matcher)
- **ADR-0031 addendum** appended documenting the classic-cert limitation and the switch to
  Certificate Manager; notes the CNAME must remain permanently for auto-renewal.
- `terraform plan` confirmed: **4 to add, 0 to change, 0 to destroy**; static IP shows
  0 changes (already in state).
- `terraform fmt` and `terraform validate` clean.

### Phase 8b.1 — LB Foundation: ADR + APIs + Static IP + Wildcard Cert (infra, July 2026)

First slice of the Global External HTTPS Load Balancer build for wildcard subdomain
routing (`*.slotsense.chandraailabs.com`). **NOT YET APPLIED** — Coordinator must run
`make tf-apply-dev` after reviewing the plan.

- **ADR-0031** (`docs/adr/0031-load-balancer-wildcard-subdomains.md`): Documents the
  Phase 8b architecture decision — additive LB alongside existing Firebase Hosting,
  URL map path routing for API vs. frontend, Cloud Armor attachment, Cloud Run ingress
  restriction as the final step, and `slotsense.chandraailabs.com` as the target domain
  (product rename from `sportbook`).
- **APIs enabled** (`gcloud services enable`, documented in `terraform/apis.tf` locals):
  - `compute.googleapis.com` — required for all LB/networking resources
  - `networksecurity.googleapis.com` — required for Cloud Armor (Phase 8b.3)
- **`terraform/load_balancer_network.tf`** (new file, 2 resources):
  - `google_compute_global_address.slotsense_lb_ip` — reserved static global IPv4 at
    name `slotsense-lb-ip`; DNS A record for `*.slotsense.chandraailabs.com` should
    point here before the LB is fully wired.
  - `google_compute_managed_ssl_certificate.slotsense_wildcard_cert` — managed wildcard
    cert for `*.slotsense.chandraailabs.com`; will remain `PROVISIONING` until DNS and
    the LB forwarding rule are both active.
- `terraform plan` confirmed: **2 to add, 0 to change, 0 to destroy**.
- `terraform fmt` and `terraform validate` clean.

### Agent Facility Resolution Reliability (backend, July 2026)

Prompt-level fix for facility matching on the AI agent. **Requires live manual
verification** — automated tests confirm the instruction text is present in the
rendered system prompt, but cannot verify that the LLM follows the instructions.

- **`_facility_list_text`** (`orchestrator.py`): Each facility line now includes
  `(sport=...)` alongside the name and id, e.g.
  `- North Court (sport=badminton) (id=abc123)`. Gives the model a cleaner signal
  when the user refers to a sport rather than a facility name. Falls back to
  `facility_type_id` when the `sport` field is absent.
- **Disambiguation rules** (`_SYSTEM_TEMPLATE`, `orchestrator.py`): Three new
  rules appended to the system prompt:
  - `FACILITY MATCHING` — only use a `facility_id` that appears verbatim in the
    "Known facilities" list; never invent or derive one from a sport name.
  - `AMBIGUOUS FACILITY` — if a sport/name matches more than one facility, do NOT
    call any tool; ask the user to choose by listing the matching names.
  - `UNRESOLVABLE FACILITY` — if no match can be found, tell the user and do not
    call any tool.
- **Tests:** 6 new tests (372 → 378, 0 failed):
  - `test_agent.py`: `_facility_list_text` renders sport + id for non-obvious
    fixture; falls back to `facility_type_id`; empty returns placeholder; system
    prompt contains `FACILITY MATCHING`, `AMBIGUOUS FACILITY`, and
    `UNRESOLVABLE FACILITY` text.
  - `test_agent_booking.py`: `_facility_list_text` renders sport for booking-suite
    fixture; system prompt includes `(sport=tennis)` for the facility.
  - All new tests are labelled where applicable: "verifies instruction is PRESENT
    in prompt text; does NOT verify the LLM follows it — requires live manual
    testing."

### Clone Facility + Edit-Dialog Scroll Fix (frontend, July 2026)

Two improvements to the tenant-admin facility management flow.

- **Clone facility** (`TenantFacilities.tsx`): Added a "Clone" action per facility card. Opens the
  existing edit dialog pre-filled with the source facility's `facility_type_id`,
  `slot_duration_minutes`, and `weekly_schedule`, while `name` and `description` are explicitly
  blank (never copied). A `dialogMode: "edit" | "clone"` discriminant was added — `submitEdit`
  branches on this: `"clone"` calls `createFacility.mutateAsync` (no `id` field); `"edit"` calls
  `updateFacility.mutateAsync` (unchanged). Dialog title is dynamic: "Edit facility" / "Clone
  facility". `WeeklyScheduleEditor` key extended to `${dialogMode}-${editingFacility?.id}` so
  switching between edit and clone on the same facility still remounts cleanly. `closeEdit` resets
  mode to `"edit"` as safe default. Clone success closes the dialog; edit success shows inline
  confirmation.
- **Edit dialog scroll** (`TenantFacilities.tsx`): The form body inside `<DialogContent>` is now
  wrapped in `<div className="max-h-[70vh] overflow-y-auto pr-1">`. `DialogHeader`/`DialogTitle`
  remain outside this scrollable region and stay visible at all times. `dialog.tsx` (off-limits per
  ADR-0028) was not touched — `DialogContent` already accepts className overrides; the fix lives
  entirely at the call-site.
- **Tests:** 4 new tests — clone opens with pre-filled type/duration/schedule and blank
  name/description; clone save calls `createFacility` not `updateFacility`; Edit(A)→close→Clone(A)
  shows blanked name (no stale edit-name leak); dialog title reflects mode. All existing 7 tests
  preserved unweakened. Baseline: 257 → 261 tests, 0 failed.

### Post-v2.2 Cleanup — Edit dialog stale state, sport display name, default schedule (frontend, July 2026)

Three targeted fixes on the `fix/post-v2.2-cleanup` branch following the v2.2 merge.

- **Edit dialog stale state** (`TenantFacilities.tsx`): Added `key={editingFacility?.id ?? ""}` to the
  `WeeklyScheduleEditor` inside the edit Dialog. React tears down and recreates the component tree
  per-facility, preventing stale `draft` state from a previously opened facility from showing through
  when the admin opens a different facility's edit dialog without a full page reload.
- **Sport display name** (`TenantFacilities.tsx`, `Facilities.tsx`, `bookingHooks.ts`): Raw sport slugs
  (e.g. `"table-tennis"`) replaced with the catalog's human-readable `name` field (e.g. `"Table Tennis"`).
  `useFacilityCatalog` + `CatalogType` added to `bookingHooks.ts` (same `queryKey: ["facility-catalog"]`
  as `tenantAdminHooks.ts` — React Query cache deduplication applies). Admin list resolves by
  `facility_type_id`; resident page resolves by `sport` field (Facility interface lacks `facility_type_id`).
- **Default create schedule** (`WeeklyScheduleEditor.tsx`, `TenantFacilities.tsx`): New facilities now
  initialize the weekly schedule with `[{start:"06:00",end:"10:00"},{start:"16:00",end:"21:00"}]` on all
  7 days via `defaultCreateSchedule()`. The edit path is unaffected — it always pre-fills from the
  facility's stored schedule.
- **Tests:** Regression test for the edit-dialog stale-state bug (open A → close → open B → assert B's
  data); default schedule assertion for create form; assertion that editing shows real schedule not default;
  catalog name display test; `useFacilityCatalog` added to bookingHooks mock in `a11y.audit.test.tsx`.
  Baseline: 252 tests → 257 tests, 0 failed.

### Booking-Model v2.2 — Weekly schedule editor + facility edit flow (frontend, July 2026)

Frontend sub-phase completing the v2.1 backend migration on the client side.

- **Shared types** (`src/types/facilitySchedule.ts`): `DayName`, `TimeRange`,
  `WeeklySchedule`, and `DAY_ORDER` constant — single source of truth shared across
  both hook files and new components.
- **Interface updates:** `Facility` (bookingHooks) and `TenantFacility`
  (tenantAdminHooks) drop `open_time`/`close_time` and gain `weekly_schedule: WeeklySchedule`.
  `useUpdateFacility` typed with a proper `UpdateFacilityPayload` (no more
  `Record<string, unknown>`).
- **WeeklyScheduleEditor** (`src/components/tenant/WeeklyScheduleEditor.tsx`):
  7-day list with per-day Dialog (composed from existing `Dialog`/`Input`/`Button`
  shadcn primitives only, per ADR-0028). Per-day carry-forward pre-fill: if a day
  has zero ranges and is not Monday, it opens pre-filled with the previous day's
  ranges as an editable starting point. Inline validation (start < end,
  non-overlapping) disables Save and surfaces error before write.
- **Facility create form** (TenantFacilities): replaces `openTime`/`closeTime` plain
  text inputs with `WeeklyScheduleEditor`. Mutation payload now carries `weekly_schedule`.
- **Facility edit flow** (TenantFacilities): new "Edit" action per facility row opens
  a Dialog pre-filled with existing values (name, type, duration, description,
  weekly schedule). Wires `useUpdateFacility` — previously dead code now in active use.
  PATCH always sends the complete 7-day `weekly_schedule` object.
- **Resident-facing display** (Facilities.tsx): replaces `open_time–close_time` string
  with today's ranges resolved from `weekly_schedule` via `new Date().getDay()` weekday
  mapping. Shows "Today: HH:MM–HH:MM, …" or "Closed today" when no ranges for the day.
- **Tests:** 11 new WeeklyScheduleEditor tests; TenantFacilities updated to
  `weekly_schedule` fixtures + new edit-flow test; Facilities updated with
  `vi.setSystemTime`-based Monday/Saturday coverage; a11y audit stubs updated;
  MyBookings stale fixture fixed. Baseline: 238 tests → 252 tests, 0 failed.

### Booking-Model v2.1 — Weekly multi-range facility schedule (backend, July 2026)

Backend-only sub-phase replacing the flat `open_time`/`close_time` per-facility
fields with a `weekly_schedule: dict[str, list[TimeRange]]` structure.

- **ADR-0030** documents the decision: hard cutover (dev-only, no production data),
  `slot_duration_minutes` unchanged, day-of-week resolution inside `compute_slots`
  (signature unchanged → `create_booking` and agent orchestrator require zero changes).
- **Schema:** `FacilityCreate` and `FacilityUpdate` now carry `weekly_schedule`
  (7 required keys, each a list of `{"start": "HH:MM", "end": "HH:MM"}` ranges).
  `TimeRange` is validated: HH:MM format, `start < end`, ranges per day must be
  non-overlapping and chronologically ordered. `FacilityUpdate.weekly_schedule` is
  whole-object (PATCH replaces the full 7-day schedule — no partial-day merge, per
  ADR-0030 decision 4).
- **`compute_slots` rewrite:** resolves `date.strftime("%A").lower()` → looks up that
  day's ranges in `facility["weekly_schedule"]` → loops the existing
  slot-increment/status logic once per range, concatenating results in chronological
  order. Empty range list = closed day = zero slots returned.
- **Tests:** all 9 backend test files with facility stubs updated to `weekly_schedule`
  (`test_bookings.py` was an additional file found during the update pass, not in the
  original investigation list). Three new tests added to `test_availability.py`:
  two-range day (gap verified), closed day (empty list), different schedules on
  different days. Test count: 369 → 372.
- **Note:** the tenant-admin facility create/edit form (`TenantFacilities.tsx`) is
  intentionally broken until v2.2 lands — expected, no external users affected.

### Phase 10 complete — UI Redesign + PWA + Accessibility (PRs #48–#73, 26 PRs, July 2026)

Phase 10 raised the SlotSense frontend from functional-but-unstyled to
portfolio-quality consumer product. Key outcomes:

- **Design system:** Tailwind v4 + shadcn/ui (Radix primitives) + Inter, mapped
  onto the existing `--color-*` CSS-variable branding contract. All 14 page
  surfaces restyled. Dark mode first-class via `data-mode`/FOUC-free inline
  script. Test count grew from 107 to 238 across 37 test files.
- **PWA:** Real app icons, correct Workbox cache strategy (`no-cache` on
  navigation files, `immutable` on content-hashed assets), always-on install
  prompt with platform-aware wording. Two deploy-pipeline bugs found and fixed
  during rollout (Firebase Hosting REST API schema; `source:"/"` vs.
  `source:"/index.html"` path matching — see PRs #69–#70).
- **Co-branding:** Tenant brand is the dominant app identity; "powered by
  SlotSense" footer is the secondary platform attribution. ADR-0029 captures
  this hierarchy and forward-binds future surfaces (push notifications,
  email, install prompt). Manifest name remains "SlotSense" (install-time
  constraint; per-tenant manifest serving deferred).
- **Booking fix (PR #65):** Removed client-side date filtering in `useMyBookings`
  that was silently dropping confirmed bookings for residents in non-UTC
  timezones. Backend is now the declared single source of truth for the
  "upcoming" booking set.
- **Accessibility audit (Phase 10.5):** 28 automated axe-core scans (14 pages
  × 2 modes) — zero serious/critical violations after fixing two confirmed
  findings (unlabeled color pickers in TenantBranding; unlabeled file input in
  TenantUsers). Keyboard navigation and Radix FocusScope focus-trap confirmed.
- **ADRs:** ADR-0028 (design system + theming) and ADR-0029 (co-branding
  hierarchy).
- **Retrospective:** `docs/retrospectives/phase-10.md` — the density saga,
  deploy/cache lessons, and process improvements adopted.

### Added / Fixed (Phase 10.5 — Accessibility audit, axe-core scan, keyboard & focus-trap verification)

- **Automated axe-core audit added (`src/a11y.audit.test.tsx`):** 44 tests covering all 14 key
  pages (SignIn, Facilities, FacilityAvailability, MyBookings, Account, Assistant,
  TenantDashboard, TenantFacilities, TenantUsers, TenantPolicies, TenantBranding,
  TenantList, CreateTenant, CreateUser) in both light and dark mode via `jest-axe` + vitest/jsdom.
  Zero axe `serious`/`critical` violations after fixes.
- **TenantBranding — two unlabeled `<input type="color">` fixed (confirmed `label` violation):**
  Primary-color and secondary-color pickers had visible `<label>` text but no `htmlFor`/`id`
  association, so screen readers could not announce the label. Added `htmlFor="brand-primary-color"`
  / `id="brand-primary-color"` and the same for secondary. No visual change.
- **TenantUsers — unlabeled `<input type="file">` fixed (confirmed `label` violation):**
  The CSV bulk-import file picker had no accessible name. Added
  `aria-label="Upload CSV for bulk user import"`. No visual change.
- **Keyboard navigation verified:** Tab order confirmed through SignIn (email → password →
  show/hide toggle → submit → Google → forgot-pw), Facilities (facility links reachable),
  FacilityAvailability (date input + available slot buttons reachable; disabled slots
  correctly skipped by Tab), Account (both password fields + submit), MyBookings (Cancel button
  reachable and dialog opens via Enter).
- **ConfirmDialog focus-trap verified (Radix FocusScope):** Focus moves into dialog on open;
  10 Tab cycles stay inside the dialog (trap confirmed); Escape closes dialog and calls onCancel;
  Cancel and Confirm buttons both operable via keyboard.
- **SlotGrid accessible states verified:** Each slot button exposes its time + state text in the
  accessible name (`getByRole("button", { name: /08:00.*available/ })`), so state is not
  color/text-only. Disabled buttons are correctly `disabled`. All three states (available,
  booked, past) have visible text labels.
- **CSS contrast note:** jsdom does not compute CSS custom-property values, so color-contrast
  violations cannot be caught programmatically in this setup. The Phase 10.7 back-link contrast
  fix remains the last known contrast issue; dark-mode token values are unchanged since that fix.
  Manual verification with a real browser (Lighthouse / DevTools) is recommended on each
  token-value change per ADR-0028.
- **dep:** `jest-axe@10.0.0` + `@types/jest-axe@3.5.9` added as devDependencies.
- CI gate: 37 test files, 238 tests green; `pnpm lint` 0 errors; `pnpm build` clean;
  contract diffs empty (TenantBranding.tsx and TenantUsers.tsx — aria attributes only).

### Fixed / Changed (Phase 10.9 — Dark-mode toggle into menu; install banner clarity)

- **Dark-mode toggle relocated to hamburger menu (mobile):** The persistent moon/sun icon in
  the mobile header row (`size-9 = 72px` with `--spacing: 8px`) consumed 88px of brand space
  that is now freed. The toggle is hidden on mobile via `hidden sm:inline-flex` and rendered
  as the first item in the opened mobile nav (Button `ghost sm` with Moon/Sun icon + "Dark
  mode"/"Light mode" label). On desktop (≥640px, no hamburger) it stays in the persistent
  header row — unchanged. Keyboard accessibility, aria-label, and `applyMode()` behavior are
  fully preserved; only the toggle's DOM location on mobile changes.
- **Brand name room improvement:** With only the hamburger (72px) in the mobile right cluster,
  available brand width at 375px grows from 135px to 223px. A tenant with "RVRG Residency"
  (114px text) + 80px logo (218px total) now fits from ~266px viewport onward vs. ~394px
  previously — an 128px improvement in the breakeven width.
- **Install banner wording fix (Android/manual-hint):** The instruction `"Tap ⋮ menu →
  Install app"` was ambiguous — Coordinator confused it with the app's own ☰ hamburger. Fixed
  to `"Open your browser's ⋮ menu → Install app"`, making it unambiguous that the BROWSER's
  three-dot menu is meant (not the app's). Investigation confirmed no logic coupling between
  the Install banner's onClick handler and AppHeader's hamburger state — pure wording issue.
- CI gate: 36 test files, 194 tests green (+3 AppHeader mobile-menu toggle tests); `pnpm lint`
  0 errors; `pnpm build` clean; contract diffs empty.

### Fixed / Added (Phase 10.8 — FOUC fix, hamburger overflow fix, always-on install banner)

- **Dark-mode FOUC fix (index.html):** Added a tiny blocking (non-module) inline `<script>`
  in `<head>` that runs synchronously before any CSS is applied. It reads
  `localStorage.getItem("slotsense-theme")` and `prefers-color-scheme` and sets
  `document.documentElement.dataset.mode = "dark"` immediately if needed. This prevents the
  flash where dark-mode-aware CSS tokens (e.g. `--color-link: #1a4d8f` dark-blue, invisible
  on dark background) resolve to their light-mode values on the first paint. The existing
  `applyMode()` call in `main.tsx` continues to handle subsequent toggles. Wrapped in
  `try/catch` so any localStorage/matchMedia unavailability is silently ignored.
- **Hamburger icon overflow fix (AppHeader.tsx):** With `--spacing: 8px`, the right icon
  cluster (`dark-toggle 72px + gap 16px + hamburger 72px = 160px`) and a `shrink-0` brand
  div together overflow narrow viewports when a wide tenant logo or long brand name is
  configured. Root cause: brand div was `shrink-0` with no min-w-0, preventing compression.
  Fix: removed `shrink-0` from brand div; added `min-w-0` (allows flex shrink); logo `<img>`
  gets `shrink-0 max-w-[80px] object-contain` (capped at 80px, proportional scale); brand
  `<Link>` gets `truncate` (ellipsis if compressed). Hamburger verified in-viewport at
  320/336/375/390/414px via Playwright (with 120px logo + long brand name).
- **Always-on install banner (InstallPrompt.tsx):** The existing banner was gated on
  `beforeinstallprompt` having fired (Chrome engagement heuristic — may never fire on first
  visit). Updated to show unconditionally for any non-standalone session. States: `ready`
  (native prompt available — tapping Install calls `prompt()` directly); `ios-hint` (iOS
  Safari — shows "Tap Share → Add to Home Screen" immediately); `manual-hint` (Android/other
  before engagement — shows Install button; tapping reveals "Tap ⋮ menu → Install app"
  inline). Dismiss persists `slotsense-install-dismissed=1` to localStorage (never-show-again
  policy). Already-installed (standalone) sessions render nothing.
- CI gate: 36 test files, 191 tests green (+10 InstallPrompt tests); `pnpm lint` 0 errors;
  `pnpm build` clean; contract diffs empty.

### Fixed / Added (Phase 10.7 — SW cache freshness, install prompt, facility ordering, back-link dark-mode contrast)

- **SW cache freshness (firebase.json):** Added `headers` section to Firebase Hosting
  config. `index.html`, `manifest.webmanifest`, `sw.js`, `registerSW.js`, and
  `workbox-*.js` all get `Cache-Control: no-cache` so browsers always revalidate on
  load. Content-hashed assets under `/assets/**` keep `public, max-age=31536000,
  immutable` (safe because hash changes on each rebuild). Result: deploys immediately
  serve fresh HTML + SW; hashed assets remain efficiently cached. Effect takes hold
  after the next `firebase deploy`; verify via `curl -sI https://sport-slot-dev.web.app/
  | grep -i cache-control`.
- **SW behavior (proposed, NOT applied):** The current `registerType: "autoUpdate"` with
  `cleanupOutdatedCaches: true` is correct. With the no-cache headers above, the browser
  will fetch a fresh `sw.js` on every load. Workbox already uses `skipWaiting` and
  `clientsClaim` implicitly in `generateSW` mode. No change to SW activation behavior
  is needed or applied.
- **PWA install prompt (Facilities page):** Added `useInstallPrompt` hook
  (`src/hooks/useInstallPrompt.ts`) and `InstallPrompt` component
  (`src/components/InstallPrompt.tsx`). On Android/Chrome: listens for
  `beforeinstallprompt`, stashes it, shows "Install app" button; calls `prompt()` on
  click; hides on `appinstalled`. On iOS Safari (no `beforeinstallprompt`): detects iOS
  UA + not-standalone, shows "Install: tap Share → Add to Home Screen" hint. Already
  installed (standalone `display-mode`) → hidden. Dismissible via × button. Rendered
  above the h1 in the Facilities page (home for residents).
- **Facility ordering:** Both `Facilities` and `TenantFacilities` now sort the active
  facility list by `name` ascending using `localeCompare` before rendering. Sort applied
  in the component (no query change). Order is stable across re-renders.
- **Back-link dark-mode contrast (root cause measured):** After the 10.6j `block` fix,
  back-links are structurally correct (`display: block`, correct margins from
  `space-y-*`). The remaining "invisible" symptom is a WCAG color-contrast failure:
  `text-primary` (#1a4d8f) on the dark-mode background (#0f1115) gives a contrast ratio
  of ~2.25:1 — far below the 4.5:1 AA threshold. Fix: added `--color-link` semantic
  token to `theme.css` (`#1a4d8f` light, `#60a5fa` dark — ~4.6:1 on #0f1115). All
  navigation links (`text-primary underline`) updated to `text-link`. The `block` class
  from 10.6j is preserved on all back-links.
- CI gate: 35 test files, 181 tests green; `pnpm lint` 0 errors; `pnpm build` clean.

### Fixed (Phase 10.6j — Back-link visibility, assistant footer spacing, TenantUsers button overlap)

- **Back-link resize-to-appear bug (all pages):** In Tailwind v4, `space-y-*` applies
  `margin-block-end` via `> :not(:last-child)`. When the first child is an inline `<a>`
  (the back-link), some mobile browsers collapse its effective height on initial paint
  and only correct on resize. Fix: added `block` to every back-link `<Link>` so it is
  always a block-level element — immediate visibility on load, left-aligned with the
  container's padding edge (same as cards below). Affected: `FacilityAvailability`,
  `MyBookings`, `Account` (×2), `TenantFacilities`, `TenantUsers`, `TenantPolicies`,
  `TenantBranding`, `CreateUser`.
- **Assistant footer dead gap:** `paddingBottom: 56` on a `height: 100dvh` element in
  CSS `content-box` mode adds blank space *below* flex content (not above it) — the
  inner div becomes `100dvh + 56 px` tall, and the AuthedLayout `pb-14` (112 px) adds
  another 112 px, totalling `100dvh + 168 px` of page height and a large scrollable
  gap. Fix: changed the outer chat container to `position: fixed; inset: 0` so it is
  exactly viewport-sized with no page overflow; `paddingBottom: 72` (≥ footer height
  ~65 px) ensures the chat input sits just above the fixed footer with ~7 px clearance.
- **TenantUsers two-button overlap (mobile):** The two action buttons ("Issue temp
  password" ~188 px + "Deactivate" ~128 px + gap = ~332 px) exceeded the 326 px
  mobile container. `shrink-0` on the action div prevented shrinking, causing the
  buttons to overlay the user info text. Fix: replaced `ListRow` on user rows with a
  responsive card — `flex-col gap-2` on mobile (info block above, buttons as equal-
  width `flex-1` row below), `sm:flex-row sm:items-center sm:justify-between` on
  desktop. Both buttons keep their exact labels, handlers, and ConfirmDialog flow;
  `min-h-[40px]` ensures ≥ 40 px touch targets at all breakpoints.
- CI gate: 35 test files, 181 tests green; `pnpm lint` 0 errors; `pnpm build` clean.

### Changed (Phase 10.6i — Measurement-driven padding / width / back-link optimization)

- **Discovery:** `theme.css:86` sets `--spacing: 8px`, so Tailwind v4's `p-4` renders as
  32 px (not the 16 px assumed from v3 defaults). All padding changes below use
  measured pixel values as targets.
- fix(frontend): `ListRow` — `p-4` → `p-2` (32 px → 16 px measured) for all list rows
  across MyBookings, TenantFacilities, TenantUsers, TenantList.
- fix(frontend): `ui/card.tsx` — `py-4` → `py-3` (32 px → 24 px) on `Card`;
  `px-6` → `px-3` (48 px → 24 px) on `CardHeader`, `CardContent`, `CardFooter`.
  Narrow ADR-0028 exception — token identities untouched, only spacing values adjusted.
- fix(frontend): `Facilities`, `MyBookings`, `TenantList`, `TenantFacilities`,
  `TenantUsers` — `max-w-5xl` → `max-w-6xl` (1024 px → 1152 px) to reduce
  right-side dead space on wide viewports.
- fix(frontend): `Facilities` — promo card and facility grid tiles `p-4` → `p-2`
  (32 px → 16 px measured).
- fix(frontend): Back-links on all pages that already carried `font-medium text-primary`
  updated to `underline underline-offset-2 hover:text-primary/70` for consistent,
  prominent link affordance. Pages: `FacilityAvailability`, `Account` (×2),
  `ForgotPassword`, `ResetPassword`, `CreateUser`, `TenantBranding`, `TenantPolicies`,
  `TenantFacilities`, `TenantUsers`, `MyBookings`. `ResetPassword` also gained
  previously-missing `font-medium`.
- CI gate: 35 test files, 181 tests green; `pnpm lint` 0 errors; `pnpm build` clean.

### Fixed (Phase 10.6h — Password eye, valid assistant prompts, back-links, chat footer)

- fix(frontend): `ResetPassword` and `ForcePasswordChange` — added show/hide eye
  toggle to both "New password" and "Confirm new password" fields, matching the
  exact `Eye`/`EyeOff` lucide icon + `type="button"` + `aria-label` pattern from
  `SignIn`. States `showPw`/`showConfirm` are independent so each field can be
  revealed separately. Accessible labels: "Show/Hide password" (new-pw field),
  "Show/Hide confirm password" (confirm field).
- fix(frontend): `SuggestedPrompts` — replaced invalid example prompts
  ("What's my usual court?", "Book my usual tennis slot tomorrow",
  "Show my upcoming bookings") with valid booking/availability queries the agent
  actually handles: "Book tennis tomorrow", "Is tennis free today?",
  "Is football available tomorrow?", "Book badminton this Saturday". No agent
  logic changed. `SuggestedPrompts.test.tsx` updated to match new strings.
- fix(frontend): `Facilities` — updated Booking Assistant promo-card example text
  from "book my usual tennis slot" to "book tennis tomorrow" to match actual
  agent capability.
- fix(frontend): All back-links (`← Facilities`, `← Dashboard`, `← Back`,
  `← Back to tenants`, "Back to sign in") across nine pages — added
  `font-medium` to the shared className for clearer, consistent link affordance.
  `CreateUser` also gained `text-sm` (previously missing).
- fix(frontend): `Assistant` — added `paddingBottom: 56` to the outer
  `height: 100dvh` flex container. This reduces the usable column height by 56px
  (matching AuthedLayout's `pb-14`), so the MessageInput area clears the fixed
  "powered by SlotSense" footer without hiding any chat content.
- CI gate: 35 test files, 180 tests green.


### Added (Phase 10.6g — Standard list row system)

- feat(frontend): Introduced `<ListRow>` component (`src/components/ListRow.tsx`)
  as the single source of truth for list row layout: `rounded-lg border bg-card p-4
  flex items-center justify-between gap-3`. Content area gets `min-w-0 flex-1` (enables
  `truncate`); action area gets `flex items-center gap-2 shrink-0` (inline at all
  breakpoints). Accepts `actionClassName` for rows that need tight `flex-wrap`
  (TenantUsers two-button row).
- fix(frontend): `MyBookings`, `TenantFacilities`, `TenantUsers`, `TenantList` — all
  list rows converted to `<ListRow>`. Killed `flex-col gap-3 sm:flex-row sm:items-center
  sm:justify-between` and `self-start/sm:self-auto` patterns. Actions (Cancel,
  Remove, Deactivate, Issue temp password) are now inline at ALL breakpoints. Facility
  name, display name, and tenant name get `truncate` for overflow safety.
- fix(frontend): All five list/grid pages (`Facilities`, `MyBookings`, `TenantFacilities`,
  `TenantUsers`, `TenantList`) — `max-w-3xl` → `max-w-5xl` on main container.
- fix(frontend): `Facilities` — grid breakpoint `sm:grid-cols-2` → `md:grid-cols-2`
  so single-column view persists on small tablets (768px is the new break).
- fix(frontend): `TenantList` — `+ Add admin/user` link promoted from inline content
  to `ListRow` action area; consistent right-aligned placement with all other action rows.
- CI gate: 35 test files, 180 tests green.

### Added (Phase 10.6e — Responsive multi-column facility grid)

- feat(frontend): Facility tiles now lay out in a responsive grid:
  `grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3` (1 mobile / 2 tablet / 3
  desktop). Tiles remain plain bordered `<Link>` blocks (no Card) — grid stretch
  gives clean equal-height tiles per row without the dead-space bug. Booking
  Assistant card stays full-width above the grid (not a grid item). `h-full` not
  needed: plain `<Link>` block has no inner flex column; stretch is already clean.
- CI gate: 35 test files, 180 tests green; 0 lint errors; clean build.

### Added (Phase 10.6d — Facility list as plain rows; change-password close)

- fix(frontend): Root cause of tall list rows confirmed: `<div class="grid"> →
  <Card flex flex-col>` where `align-items: stretch` inflated single-child flex
  cards to fill the grid row height. Prior `py-0`/`gap-3` fixes addressed padding
  but not the grid-stretch root.
- fix(frontend): `Facilities.tsx` — converted facility list from `grid → Card →
  CardContent → Link` to plain bordered `<Link>` rows (`space-y-3` stack,
  `rounded-lg border bg-card p-4`), matching the existing Booking Assistant card
  pattern. `Card`/`CardContent` imports removed.
- fix(frontend): `MyBookings.tsx` — converted booking list from `grid → Card →
  CardContent` to plain bordered `<div>` rows (`space-y-2`); mobile stacking
  (flex-col sm:flex-row) and Cancel/Cancellation-closed affordances preserved.
  `Card`/`CardContent` imports removed.
- fix(frontend): `TenantList.tsx` — converted tenant list from `grid → Card →
  CardContent` to plain bordered `<div>` rows; "+ Add admin/user" link preserved.
  `Card`/`CardContent` imports removed.
- fix(frontend): `TenantFacilities.tsx` — converted facility list from
  `grid → Card → CardContent` to plain bordered `<div>` rows; Remove button,
  ConfirmDialog flow, and mobile stacking preserved. `Card`/`CardContent` imports
  removed.
- fix(frontend): `TenantUsers.tsx` — converted user list from `grid → Card →
  CardContent` to plain bordered `<div>` rows; Issue temp password + Deactivate
  buttons, ConfirmDialog flow, and mobile stacking preserved. `Card`/`CardContent`
  imports removed.
- fix(frontend): `Account.tsx` — added `← Back` link to `/` on the Change password
  form so users can exit without submitting.
- note(frontend): `ForcePasswordChange.tsx` — NOT given a back link. This page is
  the mandatory gate for temp-password accounts; `ProtectedRoute` redirects back
  to it until `mustChange = false`. A back link would bypass the security gate.
  The existing "Sign out" button is the correct and intentional escape hatch.
- CI gate: 35 test files, 180 tests green; 0 lint errors; clean build — verified
  with both `.env` and `.env.local` absent.

### Added (Phase 10.6c — Root card density, sticky footer, platform name, assistant icon)

- fix(frontend): Root card density — `Card` primitive spacing tightened:
  `gap-6 → gap-3` (24px→12px between children), `py-6 → py-4` (24px→16px
  outer vertical padding). Root cause of oversized cards app-wide. All per-page
  `py-0` overrides from 10.6b remain correct and needed (list-row cards
  intentionally zero the Card outer padding so only `CardContent.p-4` controls
  spacing). Full before/after: `flex flex-col gap-6 ... py-6` →
  `flex flex-col gap-3 ... py-4`. Only the two spacing utilities changed;
  all other Card attributes, exports, and sub-components untouched.
- fix(frontend): Footer always visible — changed from `min-h-screen flex flex-col`
  (only pinned on short pages) to `fixed bottom-0 left-0 right-0 z-10
  bg-background` (always visible on both short and long pages). `pb-14` (56px)
  added to the content wrapper so the last list item is never hidden behind the
  ~50px fixed footer. `sticky bottom-0` was rejected: it only sticks when the
  element approaches the viewport bottom while scrolling, not from the top —
  on a long page the footer is not visible until you scroll to the very bottom.
- fix(frontend): SignIn title `SportSlot` → `SlotSense` (platform login brand).
  Updated `SignIn.test.tsx` and `app.render.test.tsx` to assert "SlotSense"
  (intended string change, not a test weakening).
- fix(frontend): Booking Assistant card emoji `🤖` → `<Bot>` lucide icon in
  `Facilities.tsx`, sized `size-4`, consistent with the app icon system.
- CI gate: 35 test files, 180 tests green; 0 lint errors; clean build — verified
  with both `.env` and `.env.local` absent.

### Added (Phase 10.6b — Density and layout polish)

- fix(frontend): Removed forced Card dead-space — `Card` primitive has `py-6` (48px outer
  vertical) baked in; TenantFacilities, TenantUsers, TenantList, and MyBookings cards now
  add `py-0` to neutralize it. Cards size to content; Facilities was already correct.
- fix(frontend): Mobile stacking — all list cards (TenantFacilities, TenantUsers, MyBookings)
  changed from `flex items-center justify-between` to `flex flex-col gap-3 sm:flex-row
  sm:items-center sm:justify-between`. Action buttons no longer clip off-screen on narrow
  viewports; touch targets remain ≥44px.
- fix(frontend): Footer pinned to viewport bottom — `AuthedLayout` now uses `min-h-screen
  flex flex-col` wrapper with `flex-1` content div. Footer stays at viewport bottom on short
  pages; appears below content on long pages; does not overlap or break scroll.
- fix(frontend): De-emphasized Remove/Deactivate triggers (ADR-0028 §5) — changed default
  text color from `text-destructive` (permanently red) to `text-muted-foreground`; danger
  color now appears only on hover (`hover:text-destructive hover:bg-destructive/10`).
  ConfirmDialog confirm flow unchanged; accessible names unchanged.
- note(frontend): Shared max-w container (STEP 3) — all pages already carry per-page
  `max-w-3xl`/`max-w-lg` on `<main>`. AuthedLayout cannot add max-w around Outlet without
  clipping AppHeader's full-width `border-b` (AppHeader is inside the Outlet, rendered by
  each page). No shared wrapper needed.
- note(frontend): Form input height (STEP 6) — Input primitive already uses `h-9` (36px
  standard control height). All forms are already width-capped (`max-w-md`/`max-w-lg`).
  No change required.
- CI gate: 35 test files, 180 tests green; 0 lint errors; clean build — verified with both
  `.env` and `.env.local` absent.

### Added (Phase 10.6a — SlotSense identity + footer co-branding)

- feat(frontend): Replaced all four placeholder PWA icons/favicon with the real SlotSense
  mark generated from `frontend/public/slotsense-icon-source.png` (1024×1024 PNG).
  Generation script: `frontend/scripts/gen-icons.mjs` (sharp; documents reproducible
  icon pipeline). Maskable variant composites source at 80% scale onto navy `#1a4d8f`
  canvas so the SS glyph + court-lines stay inside the safe-area circle.
- feat(frontend): Added `SlotSenseWordmark` component — flat inline SVG (navy `#1a4d8f`
  rounded square with white "SS", 18×18) + "SlotSense" text span. Crisp at 13–20px;
  no gradients; themeable via `className`; accessible visible text. 2 render tests.
- feat(frontend): Wired "powered by SlotSense" footer into app shell via `AuthedLayout`
  (React Router layout route). Footer appears on all authed routes (resident, tenant-admin,
  platform-admin); omitted on bare auth pages (SignIn, ForgotPassword, ResetPassword,
  ForcePasswordChange). Tenant header (logo + name) in AppHeader is UNCHANGED.
- CI gate: 35 test files, 180 tests green; 0 lint errors; clean build (precache 8 entries)
  — verified with both `.env` and `.env.local` absent.

### Added (Phase 10.4 — PWA manifest + icons)

- fix(frontend): Renamed PWA `name`/`short_name` from "SportSlot" → "SlotSense" in
  `vite.config.ts` manifest block; confirmed no "sportslot" string remains in
  `dist/manifest.webmanifest`.
- feat(frontend): Populated `icons: []` with three real entries (192×192, 512×512,
  maskable 512×512); all PNG files added to `frontend/public/` and emitted to
  `dist/` by Vite's static asset pipeline.
- feat(frontend): Added `favicon-32x32.png` to `frontend/public/`; wired in
  `index.html` via `<link rel="icon" type="image/png" sizes="32x32">`.
- fix(frontend): Updated `<title>` in `index.html` from "SportSlot" → "SlotSense".
- **PLACEHOLDER icons** — `pwa-192x192.png`, `pwa-512x512.png`, `pwa-maskable-512x512.png`,
  and `favicon-32x32.png` are generated navy (#1a4d8f) + white "S" PNGs; flagged for
  replacement with real brand artwork before public launch.
- **SW refresh story** (`registerType: "autoUpdate"`): new SW installs and activates
  immediately on next deploy; `skipWaiting()` + `clientsClaim()` ensure open tabs switch
  to new assets without a user prompt.
- feat(frontend): Added `workbox: { cleanupOutdatedCaches: true }` — prunes stale
  precache entries from previous deploys on SW activation; zero user-facing impact.
  Confirmed `e.cleanupOutdatedCaches()` call emitted in `dist/sw.js`.
- CI gate: 34 test files, 178 tests green; 0 lint errors; build clean — verified with
  both `.env` and `.env.local` absent.

### Added (Phase 10.3e �� Platform-admin pages; Phase 10.3 complete)

- feat(frontend): Restyled TenantList onto Card/CardContent tenant rows; real `<h1>/<h2>`;
  "+ New tenant" as `Button asChild` Link; styled loading, error, and empty ("No tenants yet.")
  states; tabular-nums for slug/status line; inline style objects removed.
- feat(frontend): Restyled CreateTenant onto labeled Input form + Button; real `<h1>`;
  token utilities; error state uses `text-destructive`; inline styles removed. No AppHeader
  (standalone form, unchanged from existing behavior).
- feat(frontend): Restyled CreateUser onto labeled Input form + Button; real `<h1>` for
  both form state and success state; token utilities throughout. Credential/temp-password
  flow PRESERVED: `CredentialDisplay` usage, `created` state shape, "Add another" button
  (→ `Button variant="outline"`), "← Back to tenants" link, and copy affordance unchanged.
  Native `<select>` kept for combobox role compatibility with all 7 existing tests.
- test(frontend): Added TenantList.test.tsx (6 tests: headings, "+ New tenant" link href,
  tenant row render, loading, error, empty state). Mocks: AppHeader, adminHooks direct —
  no importOriginal, CI-safe.
- test(frontend): Added CreateTenant.test.tsx (3 tests: heading, submit button, fallback
  error on non-ApiClientError rejection). Mocks: adminHooks, lib/api direct — CI-safe.
- No destructive one-click actions found in TenantList, CreateTenant, or CreateUser.
- **Phase 10.3 (page restyle) COMPLETE.** All pages — auth, resident, booking grid,
  tenant-admin, platform-admin — are now on the design system. 178 tests green.

### Added (Phase 10.3d — Tenant-admin pages restyle)

- feat(frontend): Restyled TenantDashboard onto Card-style Link grid; real `<h1>`;
  token utilities; inline style objects removed.
- feat(frontend): Restyled TenantFacilities onto Card/CardContent rows; real `<h1>/<h2>`;
  labeled Input/select form; Button primitives; styled loading/error/ok states;
  tabular-nums for facility times. Applied ADR-0028 §5 destructive posture: "Remove"
  is now a de-emphasized ghost trigger → ConfirmDialog confirm before deactivate fires.
- feat(frontend): Restyled TenantPolicies onto labeled Input form; real `<h1>`; Button
  submit; token utilities throughout; inline style objects removed.
- feat(frontend): Restyled TenantUsers onto Card/CardContent user rows; real `<h1>/<h2>`;
  labeled Input/select form; "Issue temp password" → Button variant="outline";
  "Deactivate" → de-emphasized ghost trigger → ConfirmDialog confirm before mutate fires
  (ADR-0028 §5); tabular-nums on bulk report counts.
- feat(frontend): Restyled TenantBranding (presentation only) onto labeled Input form;
  color-picker chrome with token classes; Button submit; token utilities. Branding
  read (useQuery/apiFetch/useEffect prefill) and write (submit handler/body construction/
  updateBranding.mutateAsync) are unchanged — ADR-0028 load-bearing logic untouched.
- test(frontend): Updated TenantFacilities.test.tsx deactivate test to click through
  ConfirmDialog (trigger → dialog confirm → mutate); imported `within`.
- test(frontend): Added TenantDashboard.test.tsx (2 tests: heading, nav links).
- test(frontend): Added TenantPolicies.test.tsx (3 tests: heading, button, pending state).
- test(frontend): Added TenantBranding.test.tsx (3 tests: heading, label, button).
  Mocks: AppHeader, AuthContext (claims=null → query disabled), tenantAdminHooks,
  lib/api — no importOriginal, CI-safe. Total: 169 tests green.

### Added (Phase 10.3c — Booking grid restyle: SlotGrid, FacilityAvailability, MyBookings)

- feat(frontend): Restyled SlotGrid.tsx — available slots use `bg-success text-success-foreground`
  token utilities; non-bookable slots use `bg-muted text-muted-foreground`; "available" label added
  to bookable slots so state is conveyed by text AND color, never color alone. Inline styles replaced
  with `cn()` + Tailwind token utilities; `min-h-[44px]` touch targets; `tabular-nums` on times;
  responsive `auto-fill minmax(96px,1fr)` grid; empty state renders "No slots available." paragraph.
  Peak token N/A — `Slot` type has no peak/premium field.
- feat(frontend): Restyled FacilityAvailability.tsx — real `<h1>` heading; labeled date `<input>`
  with token-class border/ring styling; slot-state legend (color swatch + text label for available
  and unavailable); quota advisory and feedback banners use token utilities; ConfirmDialog error
  text uses `text-destructive`. All inline `style={}` props removed.
- feat(frontend): Restyled MyBookings.tsx — booking rows use Card/CardContent primitives; Cancel
  uses `<Button variant="destructive" size="sm">`; facility name and date/time line use token
  utilities with `tabular-nums`; feedback banner uses `text-success`; all 5 existing tests green.
- test(frontend): Expanded SlotGrid.test.tsx from 1 → 6 tests: existing onPick/disabled guard,
  "available" label shown on bookable slot, reason label ("booked") shown on non-bookable slot,
  booked button `toBeDisabled()`, available button `not.toBeDisabled()`, empty slots renders
  "No slots available." message.
- test(frontend): Added FacilityAvailability.test.tsx (5 tests: Availability heading, date input,
  loading state, slot render from API, quota advisory). Mocks: `bookingHooks` (direct, no
  importOriginal) + `lib/api` — no Firebase chain loaded, CI-safe. Total: 161 tests green.

### Added (Phase 10.3b — Resident pages (Facilities, Account) + auth density)

- feat(frontend): Restyled Facilities.tsx onto Card/Button/token utilities with real <h1>
  heading, styled loading/empty/error states, tabular-nums for open/close times, and
  Button primitive for the "My bookings" nav link. Added empty-state text.
- feat(frontend): Restyled Account.tsx using AuthCard wrapper; Input/Button primitives
  with labeled fields; token utilities throughout. Placeholders preserved verbatim.
- test(frontend): Added Facilities.test.tsx (7 tests: heading, facility render, link href,
  loading, error, inactive filter, empty state). Total: 151 tests green.
- fix(frontend): Auth card density tightened — AuthCard CardContent: space-y-4 → space-y-3;
  form field spacing: space-y-3 → space-y-2. Input height unchanged (touch targets kept).
  All 19 auth page tests green after change.

### Added (Phase 10.3a — Auth flow restyle + font cleanup)

- feat(frontend): Restyled SignIn, ForgotPassword, ResetPassword, ForcePasswordChange onto
  Card/Input/Button + Tailwind token utilities via a shared AuthCard wrapper (max-w-sm,
  centered, dark-safe, responsive). All roles/labels/text/handlers preserved verbatim.
  Inline style props replaced with token utilities (text-primary, text-destructive,
  text-muted-foreground, bg-background). No raw hex values introduced.
- test(frontend): Added SignIn.test.tsx (6 tests: heading, email label, password label,
  sign-in button, forgot-password link, Google button). Total: 144 tests green.
- feat(frontend): Inter trimmed to weights 400/500, latin + latin-ext subsets only
  (was 400/500/600, all subsets). 42 font files → 8. No 600, no cyrillic/greek/vietnamese.

### Added (Phase 10.2c — Responsive shell, dark mode, Inter)

- feat(frontend): @fontsource/inter 5.2.8 self-hosted; weights 400/500/600 imported
  in main.tsx; Inter woff2 files emitted to dist/assets (no render-blocking CDN request).
- feat(frontend): Dark-mode controller (src/lib/themeMode.ts) — getInitialMode() follows
  system preference then localStorage("slotsense-theme"); applyMode() sets/removes
  documentElement.dataset.mode only; does NOT touch --color-* variables (ADR-0028 §4).
  Initialized in main.tsx before first render (no flash).
- feat(frontend): Responsive AppHeader shell — desktop: full horizontal nav; mobile (<sm):
  nav collapses behind a hamburger (Menu/X icon); opening reveals nav children + Account +
  Sign out; all touch targets >= 44px. Dark-mode toggle (Sun/Moon) reachable at all widths.
- test(frontend): 10 themeMode unit tests; 9 new AppHeader tests (toggle, mobile menu,
  dark mode × branding coexistence); 138 total tests green.
- Verified: dark mode coexists with runtime tenant branding — applyMode() never
  clobbers --color-primary overrides applied by branding.ts (ADR-0028 §4).

### Added (Phase 10.2b — Base primitives + first component restyle)

- feat(frontend): shadcn primitives installed: button, card, dialog, input, badge,
  select (class-variance-authority 0.7.1 also installed as required peer dep).
- feat(frontend): AppHeader restyled with Button primitive, lucide LogOut icon, and
  Tailwind token utilities; all roles/labels/text preserved, tests green.
- feat(frontend): ConfirmDialog restyled onto the Dialog primitive; destructive action
  posture per ADR-0028 §5 (confirm = destructive variant, cancel = outline/ghost).
  All roles/accessible names/text preserved; dedicated ConfirmDialog.test.tsx added.
- test(frontend): 8 new ConfirmDialog unit tests; total 118 tests green.
- Verified runtime theming flows to live components: --color-primary CSS variable
  channel confirmed via smoke test; utility indirection proven via build probe.

### Added (Phase 10.2a — Design-system token foundation)

- feat(frontend): Tailwind CSS v4 (@tailwindcss/vite 4.3.1), shadcn scaffolding
  (components.json, cn util in src/lib/utils.ts), and lucide-react installed.
- feat(frontend): theme.css evolved into the token layer: @import tailwindcss,
  @theme block mapping shadcn tokens onto the existing --color-* contract, neutral
  scale (slate), success/warning/ring tokens, and [data-mode="dark"] overrides
  (ADR-0028).
- feat(frontend): @/* path alias configured in tsconfig.json and vite.config.ts.
- feat(frontend): Tenant-branding runtime contract preserved: branding.ts unchanged;
  accent-color: var(--color-primary) in body ensures brand overrides flow through
  even before components migrate to Tailwind utilities.
- feat(frontend): Backward-compatibility aliases (--color-text, --color-text-muted,
  --color-danger, --spacing) retained for existing inline styles; no component
  restyled in this slice.
- test(frontend): 3 unit tests for cn() utility; total 110 tests green.

### Fixed (Slice 6.7)

- fix(frontend): MyBookings page filters to upcoming+confirmed (Phase 9
  slice 6.7). Aligns the page with the agent's list_my_bookings behavior
  (slice 6.1b). Past bookings and cancelled bookings are hidden from the
  default view. Derived `today = new Date().toISOString().slice(0,10)` and
  filter `b.status === "confirmed" && b.date >= today` replaces the
  previous `status === "confirmed"` only filter. Underlying /bookings/mine
  API is unchanged. Existing test fixture date updated from "2026-06-15"
  (past) to "2027-01-15" so existing tests pass. New test
  "filters past and cancelled bookings from display" verifies all three
  cases: past confirmed hidden, future confirmed shown, future cancelled
  hidden. 107 frontend tests, tsc clean.

### Fixed (Slice 6.6)

- fix(quota): execute-time quota check now filters by sport (cross-sport
  non-interference, Phase 9 slice 6.6).
  Root cause: create_booking_with_quota counted all confirmed bookings for
  (uid, date) regardless of sport, so a single tennis booking consumed the
  badminton quota too. Policy key is max_slots_per_user_per_sport_per_day —
  per-sport enforcement was already correct in the propose-time check
  (slice 6.4b) but broken at execute-time.
  create_booking_with_quota signature gains sport: str = "" and
  facilities: list[dict] | None = None. Inside the transaction the
  query is unchanged (uid + date + confirmed — no new Firestore index
  needed); Python-side filtering then counts only same-sport bookings by
  looking each booking's facility_id up in the passed-in fac_by_id dict.
  Unknown/missing facility_id is skipped defensively.
  create_booking in services/bookings.py: imports list_facilities, derives
  sport from the already-fetched facility, fetches facilities via
  list_facilities, and threads both into _quota_create_fn.
  test_cancelled_document_is_superseded: still passes (uses default
  sport="" so same_sport_count=0, quota not triggered by the empty iter).
  2 new hermetic tests: test_quota_cross_sport_does_not_block (tennis
  booking does not consume badminton quota) and test_quota_same_sport_raises
  (tennis booking correctly consumes tennis quota → QuotaExceededError).
  364 backend tests, 91.12% coverage.

### Fixed (Slice 6.5)

- fix(agent): correctness pass — limit fix, AM/PM guard, stateful cancel
  disambiguation (Phase 9 slice 6.5).
  6.5(a) _dispatch_readonly list_my_bookings branch no longer uses the
  LLM-supplied limit (was capped at 20). Changed to limit=100. Root cause:
  Firestore returns docs in document-ID order; with limit≤15 a user with
  15+ past bookings sees 0 future bookings after the confirmed+date≥today
  filter. Now passes 100 to surface all near-future bookings. 1 regression
  test added (verifies limit=100 kwarg and total_bookings count in turn-2).
  6.5(b) Python AM→PM guard added to _dispatch_book between the hallucination
  guard and the availability check. If hour<12 AND the datetime formed by
  combining date_str+start with the tenant timezone is already past, start is
  advanced to hour+12 (e.g. "09:00" → "21:00"). Reads tenant timezone from
  PolicyService; falls through silently on any error so availability check is
  always reached. Logged as agent_book_am_past_advanced_to_pm. 2 hermetic
  tests added (past date triggers guard; future date does not).
  6.5(c) Stateful cancel disambiguation. PendingActionStore.propose() now
  also writes a secondary pointer key
  agent_pending_latest:{tenant_id}:{uid}:{action_type} → action_id (same
  TTL). New get_latest_for_user(ctx, action_type) reads the pointer then the
  main key (read-only, does not consume). _dispatch_cancel n_can≥2 branch now
  stores a cancel_disambiguation pending action containing the candidates list
  ({id, facility_id, date, start, end} per booking). run_agent pre-Vertex
  check: if a pending cancel_disambiguation exists and the user's message
  contains exactly one candidate's date AND start as substrings, consumes the
  disambiguation action, proposes a cancel pending action for the matched
  booking, and returns a confirm prompt without calling Vertex. No match or
  zero/multiple matches falls through to normal Vertex turn. New helper
  _match_disambig_candidate implements the substring matching rule. 3 hermetic
  tests: selection routes to cancel, unrelated message falls through to Vertex,
  consumed state does not interfere. Existing two multi-candidate tests updated
  (now expect 1 propose_call for cancel_disambiguation, not 0).
  362 backend tests, 91.05% coverage.

### Fixed (Slice 6.4)

- fix(agent): error mapping + propose-time quota + cancel differentiation
  (Phase 9 slice 6.4).
  6.4(a) Booking errors in run_agent_confirm now mapped by exc.code (not
  HTTP status): SLOT_CONTENDED, BOOKING_QUOTA_EXCEEDED, ALREADY_BOOKED,
  LOCK_UNAVAILABLE, SLOT_NOT_BOOKABLE, FACILITY_NOT_FOUND, INVALID_DATE
  each produce a distinct NL message. BOOKING_QUOTA_EXCEEDED includes the
  sport name (facility looked up from params). Old status-code branching
  meant 3 different 409 codes all produced "That slot was just taken."
  6.4(b) Propose-time quota check added to _dispatch_book after the
  availability read-validate and before store.propose(). Counts the user's
  confirmed same-sport same-date bookings against
  max_slots_per_user_per_sport_per_day. Returns early with a quota message
  if at limit, preventing a proposal that would fail at execute time.
  Execute-time check in create_booking retained (defense in depth). Falls
  through silently on any policy read error so the execute-time check
  remains the safety net.
  6.4(c) _filter_cancel_candidates now returns (cancellable, too_late)
  tuple instead of a single list. _dispatch_cancel differentiates:
  (0,0) → "no bookings"; (0,≥1) → "past cancellation cutoff" message
  naming the facility and date; (1,*) → existing propose flow;
  (≥2,*) → existing disambiguation flow. Users now see precisely why
  a cancellation can't proceed instead of a misleading "no bookings" reply.
  New _booking_sport helper resolves sport for a booking via facility list.
  12 existing TestFilterCancelCandidates tests updated for tuple return;
  1 stale 422 assertion updated (SLOT_NOT_BOOKABLE message changed).
  13 new hermetic tests added. 356 backend tests, 91.68% coverage.

### Fixed (Slice 6.3)

- fix(agent+notifications): move enqueue_notification from HTTP router to
  services/bookings.py:create_booking so agent-confirmed bookings now
  produce booking-confirmation emails (regression introduced when the
  notification block was written into the router handler in Slice 3, before
  the agent path existed). Both manual (/bookings POST) and agent
  (run_agent_confirm) paths now go through the same service-layer call.
  Patch path for existing tests updated from api.v1.bookings.* to
  services.bookings.*. New hermetic test confirms source="agent" enqueues
  booking_confirmed with the correct email + params. [6.3-A]
- feat(frontend): assistant empty-state heading changed to "SlotSense";
  subtext updated to describe the assistant's scope. [6.3-B]
- feat(agent): ambiguous-time rule added to _SYSTEM_TEMPLATE — when the
  user gives a bare hour without AM/PM (e.g. "7", "8 o'clock") the model
  prefers the future-facing 24-hour interpretation relative to current local
  time. Test assertion added to test_agent_preferences.py. [6.3-C]
  344 backend tests, 106 frontend tests, tsc clean.

### Added (Slice 6)

- feat(agent+frontend): polish pass after live testing (6.1 + 6.2).
  6.1(a) 12-hour AM/PM time display in proposal cards — frontend
  formatTime12 util (lib/timeFormat.ts); ProposalCard now renders
  "9:00 AM – 10:00 AM" instead of raw HH:MM. Agent NL replies remain
  24-hour (scope choice: LLM prompt change deferred).
  6.1(b) list_my_bookings agent dispatch filters to upcoming+confirmed
  only — past bookings and cancelled bookings hidden from the LLM view.
  Underlying service (/bookings/mine route, MyBookings.tsx) unchanged.
  6.1(c) Dismissed proposal cards now hide silently — no "Proposal
  dismissed." text remains in the thread.
  6.1(d) System prompt routes 'my bookings' / 'my reservations' / 'my
  schedule' / 'what do I have' / 'what's coming up' phrasings to
  list_my_bookings. Do not refuse such questions.
  6.2 AgentRequest.recent_context optional field (backward compatible,
  defaults None) carries the previous turn for lightweight cross-turn
  context — single-turn lookback only. Backend: new _recent_context_text
  helper; {recent_context} slot in system prompt rendered conditionally.
  Frontend: useAgentSendMessage now takes {message, recent_context?};
  lastUserAndAgentTurn helper in agentSession.ts assembles context from
  the sessionStorage thread before each send. 343 backend tests, 91.31%
  coverage; 106 frontend tests. [6.1+6.2]

### Added (Slice 5b)

- feat(frontend): chat UI for the booking assistant (Phase 9 slice 5b).
  Dedicated /assistant route with structured proposal cards (Confirm/Cancel),
  sessionStorage thread persistence per-tab, 5-min pre-emptive button disable
  (timer seeded from message timestamp so expiry survives refresh), welcome
  screen + 4 suggested prompt chips on empty state, dashboard peer card on
  Facilities.tsx (above the facilities grid), PWA/mobile-aware (100dvh, 44pt
  tap targets). New files: pages/Assistant.tsx, hooks/agentHooks.ts,
  lib/agentSession.ts, components/assistant/{TypingIndicator, MessageBubble,
  MessageThread, MessageInput, ProposalCard, SuggestedPrompts}.tsx,
  styles/assistant.css (keyframes + hover pseudo-classes only; everything
  else inline with CSS vars). Uses existing apiFetch + AuthContext + React
  Query patterns; no new HTTP/auth layers. On confirm success the proposal
  card is dismissed and the agent's reply message appended. On dismiss
  (Cancel button) the card is replaced inline with "Proposal dismissed."
  Both states persist in sessionStorage. 85 tests pass, ESLint clean, tsc
  clean. [5b]
  Updated (5b.1): both onError handlers in Assistant.tsx route through
  errorMessageFor() in agentHooks.ts, which maps ApiClientError.code to
  the existing messageForCode catalog (e.g. SLOT_NOT_BOOKABLE → "That slot
  can't be booked.") and appends "ref: <8-char request_id>" for
  traceability. Non-ApiClientError throws produce a distinct "check your
  connection" message. 92 tests pass. [5b.1]

### Added (Slice 5a)

- feat(agent): AgentReply gains optional pending_action_summary field (Slice 5a).
  Structured proposal data returned alongside the NL reply on book and cancel
  propose paths. Book summary: action_type, facility_id, facility_name, sport,
  date, start, end (from validated slot). Cancel summary: action_type, booking_id,
  facility_name, sport, date, start, end (from candidate booking record). Failure
  paths (hallucination guard, unbookable, 0-candidates, multi-candidate,
  store error) return summary=None. Existing AgentReply consumers unaffected —
  field is optional (default None). Foundation for chat-UI structured proposal
  cards (Slice 5b). AgentTurn gains matching pending_action_summary field.
  339 tests, 91.38% coverage. [5a]

### Fixed (Slice 4.1)

- fix(agent): system prompt tuning for tool-routing reliability (4.V findings).
  Three new rules: (A) route 'usual/preferred/last/normal' preference questions
  explicitly to get_my_preferences — "Do not refuse such questions"; (B) for book
  requests, use ambient preferences from system prompt and call book directly —
  "Do NOT call get_my_preferences as a separate step before booking"; (C) MUST
  call the book or cancel tool — never describe the action in text (anti-narration
  guard, closes the Turn-2-tools-disabled dead-end). Prompt-only change; no code
  logic change. Multi-turn tool chaining deferred as a future option.
  Live re-validation in 4.1.V. 332 tests, 91.34% coverage. [4.1]

### Added (Slice 4)

- feat(agent): preference-aware replies and gap-filling (ADR-0021 §3 read-side).
  Closes the read-side of slice 2b's preference memory. New
  services/agent/preferences.py: get_preferences() reads
  profile.preferences.last_booked, returns empty dict on any failure (fail-open —
  preferences enrich UX, never gate access). System prompt enriched per-request:
  "Your usual bookings" section only rendered when prefs non-empty; facility names
  resolved from tenant facilities list. New GET_MY_PREFERENCES tool (5th tool,
  no args): explicit fetch for "what's my usual court?" queries; returns formatted
  map or "no remembered preferences" string. check_availability replies enriched
  at code level: after the slot grid is computed, user's usual slot status is
  appended (BOOKABLE / TAKEN(reason) / OFF-GRID-TODAY) when a preference exists
  for the queried facility's sport; sport mismatch and empty prefs → no
  enrichment line; Turn 2 framing nudges the model to mention it naturally.
  Underspecified book intents (e.g. "book tennis tomorrow") fill facility/time
  from preferences via the system prompt before hitting the existing confirm-gate.
  No confirm-gate changes; no new mutations. 331 tests, 91.34% coverage. [4]

### Added (Slice 3b)

- feat(agent): cancel via propose→confirm→execute gate (ADR-0021 §3/§4, ADR-0022
  §8). Second agent mutation. CANCEL tool (sport + optional date_hint; NO
  booking_id — hallucination structurally prevented). Deterministic Python filter
  `_filter_cancel_candidates` (status=confirmed, 7-day window, sport match,
  optional date_hint narrowing); 0/1/many branching — 0→not-found reply,
  1→pending action + confirm prompt, many→disambiguation NL list. `_parse_date_hint`
  supports YYYY-MM-DD, today/tomorrow, and weekday names. Execute path:
  cancel_booking called with stored booking_id verbatim + source="agent" →
  "agent.booking_cancelled" audit event. Cancel does NOT bypass cancel_booking's
  own ownership/buffer/status checks. 311 tests, 91.10% coverage. [3b]

### Refactored (Slice 3a)

- refactor(api): extract cancel_booking into the service layer (Phase 9 slice 3
  foundation, ADR-0021 §2); manual path behavior unchanged; source param adds
  agent audit differentiation seam (ADR-0022 §8, consistent with
  2a/create_booking): "manual"→"booking.cancelled", "agent"→"agent.booking_cancelled".
  Router thinned to a single _svc_cancel_booking call; AuditRepository +
  BookingRepository kept imported for test-patch compat. [3a]

### Added (Slice 2b)

- feat(agent): booking via propose→confirm→execute gate (ADR-0021 §4, ADR-0022
  §5/§8). First agent mutation. Structured {confirm: true, pending_action_id}
  field execute — server-enforced, not model-judged. Generic Redis
  PendingActionStore (single-use, tenant+uid scoped, 5-min TTL). BOOK tool
  (hallucination-guarded + read-validates slot is bookable before writing pending
  action). On confirm: create_booking called with stored params verbatim +
  source="agent" → "agent.booking_created" audit event. Preference memory
  partial-merge on success (best-effort). Residents-only. [2b]

### Refactored (Slice 2a)

- refactor(api): extract create_booking into the service layer (Phase 9 slice 2
  foundation, ADR-0021 §2); booking endpoint unchanged in behavior; lock + quota
  + audit semantics preserved. Router is now a thin caller + best-effort
  notification (ADR-0019). `_quota_create_fn` seam keeps existing test patches
  working without edits. [2a]

### Fixed (1b.2)

- fix(docker): set PYTHONUNBUFFERED=1 so structlog JSON logs flush to stdout and
  reach Cloud Run. 1b.1's PrintLoggerFactory was correct but Python stdout is
  block-buffered in the container by default — events sat in the buffer and were
  never scraped. One ENV line in the runtime stage; no app code change. [1b.2]

### Fixed (1b.1)

- fix(logging): structlog output now reaches stdout via PrintLoggerFactory —
  Cloud Run logs now show structured JSON lines from all service code (agent,
  auth, bookings). Previously no logger_factory was set, so structlog events
  were lost. PII redaction processors and order unchanged.
- fix(agent): system prompt now anchors current date (YYYY-MM-DD + weekday) in
  the tenant's timezone so the model can resolve relative dates ("tomorrow",
  "Saturday") before calling check_availability.
- fix(agent): list_my_bookings Turn 2 framing now pre-summarizes the tool result
  (total_bookings=N + per-booking lines) and marks it AUTHORITATIVE data, fixing
  the "wasn't able to retrieve bookings" false-failure. Diagnostic log added:
  agent_bookings_dispatched with count (no PII). [1b.1]

### Added (Slice 1b)

- feat(backend): read-only AI query agent — residents-only single-turn
  assistant (POST /api/v1/agent/query). Two tools: check_availability +
  list_my_bookings; book/cancel gated out by capability schema.
  Hallucination guard validates LLM-returned facility_id against real
  tenant list before any service call. Dual output guard: rules-based
  (email/password/uid patterns, 2 KB cap) + LLM classifier (second Flash
  call, agent_output_guard_enabled setting). Fail-closed on any Vertex or
  parse error. Uses google-genai unified SDK v2.9.0 with ADC (no API key).
  Lazy Vertex client init avoids import-time credential failures.
  14 hermetic tests — ZERO real network/Vertex calls. ADR-0021 §2 (1b).
  (review fixes: hallucination-guard test wiring; tool-schema type fidelity)

### Refactored (Slice 1a)

- refactor(api): extract get_availability and list_my_bookings into the
  service layer (Phase 9 agent foundation, ADR-0021 §2); endpoints
  unchanged in behavior. _is_cancellable moved to services/bookings.py;
  single copy shared by my_bookings and cancel_booking.

### Added (Phase 7.2.4a)

- feat(frontend): voluntary /account change-password page (no re-auth,
  ≥12 gate, stays on page on success). "Account" link in AppHeader.
- fix(frontend): ForcePasswordChange session guard — redirects to /signin
  when unauthenticated instead of failing on submit; sign-out escape hatch
  added below form.
- fix(backend): welcome-email login_url now config-driven via
  welcome_login_url setting (was hardcoded dead subdomain /login path).
- fix(frontend): admin "Reset password" button → "Issue temp password"
  to disambiguate from self-service forgot-password. ADR-0020 A2 (7.2.4a).

### Added (Phase 7.2.3)

- feat(frontend): self-service password reset pages — /forgot-password
  (enumeration-safe, uniform confirmation on success + error) and
  /reset?token=... (strips token from URL on mount, client gate ≥12
  chars, RESET_TOKEN_INVALID link-to-request). Public routes, no new
  dependencies. "Forgot password?" link on SignIn. ForcePasswordChange
  client gate bumped 8→12 for policy consistency. ADR-0020 A2 (7.2.3).

### Added (Phase 7.2.2b)

- feat(auth): self-service password reset confirm endpoint
  (/auth/forgot-password/confirm) — single-use token consume (transactional),
  policy-validated, session revocation, audit. ADR-0020 A2 (7.2.2b).

### Added (Phase 7.2.2a)

- feat(auth): self-service password reset request endpoint
  (/auth/forgot-password) — token mint, fail-closed per-email cooldown,
  branded Resend email, enumeration-safe. ADR-0020 A2 (7.2.2a).

### Added (Phase 7.2.1)

- feat(auth): shared password policy (zxcvbn + HIBP), enforced on
  /me/change-password; closed logging redaction gap (new_password,
  oobCode). ADR-0020 (7.2.1).

### Fixed (Add User field order)

- UX: reorder Add User form so Role precedes the (resident-only) Flat
  number field.

### Fixed (flat-number resident-only)

- Fix: flat_number is resident-only. API model made flat_number optional
  (was required str -> 422 when creating a tenant_admin without a flat —
  the tenant-creation 422). Frontend hides/omits the flat field unless
  role=resident. Service already enforced resident-only; now consistent
  across all three layers. Tracker: fixes the flat-field UX +
  tenant-creation 422.

### Fixed (Phase 7.x)

- Phase 7.x: forced-password gate re-prompting after a successful change.
  Root cause was NOT a query-key mismatch (`usePasswordGate.ts` and
  `ForcePasswordChange.tsx` both already used `["profile"]`) — invalidate/
  refetch defaulted to active observers; the standalone /force-password
  route has none, so the refresh was a no-op and ProtectedRoute read stale
  cached must_change_password=true on mount. Fixed by forcing type:'all'
  refetch + optimistic setQueryData before navigation. `usePasswordGate.ts`
  now exports `PASSWORD_GATE_QUERY_KEY` as the single shared key constant.
  Regression test seeds the cache with `must_change_password:true` and no
  active gate observer (mirroring the real standalone route), runs the
  change-password flow, then mounts a brand-new `ProtectedRoute` observer
  and asserts the value is correct on its very first render (no `waitFor`,
  which would mask a transient bounce back to /force-password) — confirmed
  to fail against the pre-fix code (plain `invalidateQueries`) and pass
  against the fix, per the Phase 5 false-positive lesson. Tracker: 7.x ✓.

### Added (Phase 7.1.3)

- Phase 7.1.3: wire booking-confirmed and user-welcome notification enqueues
  at their event sites; best-effort (never blocks the user action); hermetic
  tests incl. enqueue-failure isolation. `api/v1/bookings.py::create_booking`
  calls `enqueue_notification(event_type="booking_confirmed", ...)` after the
  booking is durably written (after `create_booking_with_quota` + the audit
  write, before `return doc`), resolving the booking user's email/display name
  via `UserProfileRepository(ctx, client).get(ctx.uid)` (the same pattern as
  `/users/me`) and the tenant's `display_name` via a direct tenant-doc fetch.
  `services/provisioning.py::UserProvisioningService.create_user` calls
  `enqueue_notification(event_type="user_welcome", ...)` after the existing
  create/profile/audit try-except block succeeds (deliberately outside that
  block, so an enqueue failure can never trigger the `fb_auth.delete_user`
  rollback path) — `login_url` is built from `Settings.base_domain` +
  `tenant_slug`; `temp_password` is included since it's already surfaced
  in-app via `CredentialDisplay`, the profile is created with
  `must_change_password=True` bounding its exposure window, and it's never
  logged anywhere in the enqueue/worker path. Both call sites wrap enqueue in
  a `try/except Exception` that logs a `structlog` warning and never
  re-raises — Cloud Tasks delivery failures are covered by the queue's own
  retry policy (7.1.2); this guard is only for enqueue-time failures, and the
  booking/provisioning write has already succeeded by the time it runs.
  Testability follows the codebase's existing convention for plain-function
  collaborators (matching `fb_auth.create_user`/`create_booking_with_quota`):
  `enqueue_notification` is imported directly and patched by module path in
  tests, rather than introducing a new dependency-injection wrapper. 5 new
  tests: booking-confirmed enqueue with correct `to`/params (params also fed
  through the real `render_booking_confirmed` to prove worker-side
  acceptance), booking succeeds when the enqueuer raises, enqueue skipped
  (not crashed) when no profile/email is resolvable, user-welcome enqueue
  with correct `to`/params (params fed through `render_user_welcome`), and
  provisioning succeeds when the enqueuer raises (rollback NOT triggered).
  ruff clean · bandit clean · 157 passed · coverage 92.94% (gate 90%). No
  infra/Terraform change — pure application wiring. Tracker: 7.1.3 ✓.

### Added (Phase 7.1.2)

- Phase 7.1.2: Cloud Tasks notification pipeline — queue + OIDC-authenticated
  worker endpoint + enqueue helper + invoker SA/IAM (Terraform) + resend-api-key
  secret wiring. No event triggers yet (7.1.3). `POST /internal/tasks/notify`
  (new `api/internal/` router, mounted outside `/api/v1`) verifies the Cloud
  Tasks OIDC bearer token via `google-auth`'s `id_token.verify_oauth2_token`
  (audience = worker URL, caller email pinned to `sa-tasks-invoker`); dispatches
  to the booking-confirmed/user-welcome templates and the configured
  `EmailProvider` (`ResendEmailProvider` in prod, `FakeEmailProvider` via
  `dependency_overrides` in tests); runs the sync `provider.send()` off the
  event loop via Starlette's `run_in_threadpool`. Returns 2xx on success, 503
  on `EmailSendError` (Cloud Tasks retries per the queue's `retry_config`), 422
  on unknown `event_type`/bad params (no retry), 401/403 on missing/invalid/
  wrong-SA OIDC. `notifications/tasks.py::enqueue_notification()` builds the
  Cloud Tasks HTTP task (OIDC token signed as `sa-tasks-invoker`,
  audience = worker URL); raises `TasksConfigError` loudly if queue/worker
  settings are missing rather than failing silently. Terraform
  (`terraform/cloud_tasks.tf`, Coordinator-applied): `google_cloud_tasks_queue`
  "notifications" (asia-south1, max_attempts=5, 5 dispatches/sec — Resend's
  100/day free-tier cap), new `sa-tasks-invoker` SA, `roles/run.invoker` on
  `sport-slot-api` (gcloud-deployed, not TF-managed, so bound by name/location)
  for that SA, queue-scoped `roles/cloudtasks.enqueuer` + SA-scoped
  `roles/iam.serviceAccountUser` (actAs) for `sa-cloud-run`, and
  `roles/secretmanager.secretAccessor` on the pre-existing `resend-api-key`
  secret for `sa-cloud-run`. `deploy_cloud_run.sh` now reads the service's
  existing URL before deploy (for `SPORTSLOT_WORKER_BASE_URL`) and adds
  `SPORTSLOT_TASKS_QUEUE`/`SPORTSLOT_TASKS_LOCATION`/`SPORTSLOT_TASKS_INVOKER_SA`
  env vars + `SPORTSLOT_RESEND_API_KEY=resend-api-key:latest` to `--set-secrets`.
  Narrowed `test_architecture.py`'s blanket `google.cloud` import check to
  `google.cloud.firestore` specifically (ADR-0008 Decision 3 is Firestore-only;
  the blanket match was a false positive against the new, legitimate
  `google.cloud.tasks_v2` import in `notifications/tasks.py`). 11 new tests,
  all hermetic (OIDC verification mocked, Cloud Tasks client mocked, no
  network, no real GCP). ruff clean · bandit clean · 152 passed · coverage
  92.44% (gate 90%). terraform fmt/validate clean (init-only; no plan/apply —
  Coordinator-run). Tracker: 7.1.2 ✓ (pending Coordinator `terraform apply` +
  redeploy before live).

### Added (Phase 7.1.1)

- Phase 7.1.1: EmailProvider abstraction + ResendEmailProvider + booking-
  confirmed/user-welcome templates + FakeEmailProvider + unit tests (per
  ADR-0019). `EmailProvider` is a structural Protocol (single `send()` method);
  `ResendEmailProvider` posts to the Resend HTTP API via httpx (promoted from
  dev-only to a runtime dependency), raises `EmailSendError` on non-2xx/network
  failure/missing key. Templates are pure functions returning subject+HTML+text,
  HTML-escaped via stdlib `html.escape`. `FakeEmailProvider` records sent
  messages for hermetic tests. 13 new tests, all hermetic (no network, no
  Firestore). ruff clean · bandit clean · coverage 92.05% (gate 90%).
  No Cloud Tasks / event wiring / worker endpoint yet — that's 7.1.2/7.1.3.
  Tracker: 7.1.1 ✓.

### Changed (Phase 6.3.1)

- Phase 6.3.1: remove temporary diagnostic noise from deploy_hosting_rest.sh
  (the token-length echo added during auth investigation 6.2.11–6.2.14). The
  permanent api() loud-error helper is retained. Pipeline confirmed green
  end-to-end (run 27562387259) before this cleanup. Tracker: 6.3.1 ✓.

### Added (Phase 6.1.3)

- Phase 6.1.3: grant serviceUsageConsumer to sa-firebase-admin (the impersonated
  caller for the Hosting REST deploy with X-Goog-User-Project). The principalSet
  already had this role from 6.1.1, but when auth@v3 mints a token via SA
  impersonation, the Firebase Hosting REST API enforces serviceusage.services.use
  against the impersonated SA — not the WIF principalSet. Root cause: X-Goog-User-
  Project triggers quota+billing checks on the SA's own IAM, not the WIF credential.
  Added google_project_iam_member.firebase_admin_service_usage_consumer in wif_iam.tf.
  terraform fmt OK · validate OK. Tracker: 6.1.3 ✓ (pending Coordinator apply).

### Fixed (Phase 6.2.15)

- Phase 6.2.15: translate firebase.json CLI syntax → Firebase Hosting REST API
  schema in deploy_hosting_rest.sh. firebase.json uses `source`/`destination`
  fields (CLI format) but the REST API Version.config requires `glob`/`path`.
  Sending the raw CLI fields caused 400 INVALID_ARGUMENT on version-create.
  Replaced the raw CONFIG_JSON builder with a translate() python function that
  maps source→glob, destination→path, regex→regex (passthrough), run→run
  (passthrough), and handles redirects (destination→location, type→statusCode)
  and headers (source→glob) for completeness. Verified against real firebase.json:
  output has glob/path, no source/destination keys. ShellCheck clean.
  Expected REST config: 3 Cloud Run rewrites (glob+run) + 1 SPA catch-all
  (glob:**→path:/index.html). Tracker: 6.2.15 ✓.

### Added (Phase 6.2.14)

- Phase 6.2.14: mint Firebase Hosting REST access token via sa-firebase-admin
  impersonation (token_format=access_token). Root cause confirmed: direct-WIF
  federated tokens (1484 chars) are rejected by the Firebase Hosting REST API with
  401 UNAUTHENTICATED — a real OAuth2 access token requires SA impersonation.
  Added google_service_account_iam_member.ci_token_creator_firebase in wif_iam.tf
  (principalSet→serviceAccountTokenCreator on sa-firebase-admin). Added dedicated
  auth@v3 step in deploy.yml (service_account + token_format: access_token) before
  the Hosting deploy; token passed as FIREBASE_ACCESS_TOKEN env var. REST script
  uses FIREBASE_ACCESS_TOKEN if set, else falls back to gcloud (local use).
  build/run keep direct WIF. ADR-0018 updated. terraform fmt OK · validate OK.
  ShellCheck clean · YAML valid. Tracker: 6.2.14 ✓ (pending Coordinator tf-apply).

### Fixed (Phase 6.2.13)

- Phase 6.2.13: REST Hosting deploy — revert token command to plain
  `gcloud auth print-access-token` (application-default re-exchanges the OIDC
  subject token mid-job and fails "Connection refused"; the WIF credential is
  already in the active-account store from auth@v3). Keep X-Goog-User-Project
  header (added 6.2.12). Add api() helper that prints HTTP status + response
  body on >=400 so failures are diagnosable; all JSON API calls (version-create,
  populateFiles, finalize, release) routed through it; upload calls also capture
  + print status/body on error. ShellCheck clean · bash -n clean. Tracker: 6.2.13 ✓.

### Fixed (Phase 6.2.12)

- Phase 6.2.12: REST Hosting deploy uses `gcloud auth application-default print-access-token`
  (mint token from WIF ADC, not the empty active-account store that `gcloud auth
  print-access-token` reads in CI). Added X-Goog-User-Project: sport-slot-dev header to AUTH
  array so every API call carries the quota/project context (required for ADC tokens, per
  gcloud docs; firebase-tools --debug also sends x-goog-user-project). Added token-length
  echo for debug visibility (token itself never logged). Fixes the 401 on version-create.
  ShellCheck clean · bash -n clean. Tracker: 6.2.12 ✓.

### Added (Phase 6.2.11)

- Phase 6.2.11: keyless Firebase Hosting deploy via REST API + gcloud access token.
  firebase-tools 15.x cannot consume WIF external_account ADC (confirmed via --debug:
  "No OAuth tokens found", crash on undefined.access_token). Solution: scripts/
  deploy_hosting_rest.sh drives the Firebase Hosting REST API directly with
  `gcloud auth print-access-token` (gcloud authenticates via WIF correctly — proven).
  No JSON key, no FIREBASE_TOKEN, no firebase-tools in CI. SPA rewrites + Cloud Run
  rewrites from firebase.json passed in version-create config (deep links preserved).
  Local make deploy-hosting unchanged (interactive firebase-tools login). ADR-0018
  updated with the firebase-tools WIF incompatibility finding. ShellCheck clean.
  Tracker: 6.2.11 ✓.

### Fixed (Phase 6.2.10)

- Phase 6.2.10: Firebase Hosting CI deploy via pure WIF ADC + GOOGLE_CLOUD_PROJECT.
  Official action (6.2.9) rejected — requires firebaseServiceAccount JSON key (incompatible
  with keyless WIF org policy). Reverted to firebase-tools CLI. Removed FIREBASE_TOKEN bridge
  (6.2.8). Now relies purely on GOOGLE_APPLICATION_CREDENTIALS (WIF external_account ADC, set
  by auth@v3) + GOOGLE_CLOUD_PROJECT=sport-slot-dev (lets firebase-tools resolve the project,
  which external_account files don't embed). --debug enabled until confirmed green.
  ShellCheck clean · YAML valid. Tracker: 6.2.10 ✓.

### Fixed (Phase 6.2.9)

- Phase 6.2.9: CI Firebase Hosting deploy now uses FirebaseExtended/action-hosting-deploy@v0
  (WIF/ADC), replacing the firebase-tools CLI shell invocation that failed to consume the
  WIF external-account credential after 4 attempts. The action is purpose-built for CI and
  honours GOOGLE_APPLICATION_CREDENTIALS from auth@v3; firebaseServiceAccount is empty
  (org policy forbids static JSON keys; action falls through to ADC). build-push + deploy-dev
  remain make targets (working correctly). Local make deploy-hosting unchanged.
  Install firebase-tools step removed from deploy job (no longer needed). Tracker: 6.2.9 ✓.

### Fixed (Phase 6.2.8)

- Phase 6.2.8: firebase Hosting deploy uses a gcloud-minted access token in CI —
  firebase-tools 15.x does not reliably consume the WIF external-account ADC
  (gha-creds JSON) that auth@v3 sets. gcloud authenticates correctly via WIF;
  `gcloud auth print-access-token` mints a short-lived token exported as FIREBASE_TOKEN
  for firebase-tools to consume. Keyless: no JSON service-account key, no deprecated
  login:ci token. Local deploys unchanged (interactive firebase login path). On failure
  a --debug rerun hint is printed. ShellCheck clean. Tracker: 6.2.8 ✓.

### Fixed (Phase 6.2.7)

- Phase 6.2.7: fix firebase Hosting deploy in CI — added --non-interactive so
  firebase-tools doesn't hang or emit "An unexpected error has occurred" when stdin
  is not a TTY (the root cause of the vague CI failure). --project already present;
  parametrised to ${FIREBASE_PROJECT:-sport-slot-dev} for flexibility. Added
  firebase --version echo as a debug aid before each deploy. ShellCheck clean.
  Tracker: 6.2.7 ✓.

### Fixed (Phase 6.1.2)

- Phase 6.1.2: add roles/redis.viewer to CI WIF principal (deploy reads Redis host/port
  to wire SPORTSLOT_REDIS_* env vars on Cloud Run). deploy_cloud_run.sh no longer silences
  the Redis describe error (2>/dev/null || true removed): a permission denial was being
  masked as "not found". Now runs a single describe with value(host,port), fails loudly
  with actionable message if the call fails, and derives both values from one gcloud call.
  ShellCheck clean. terraform fmt OK · validate OK. Tracker: 6.1.2 ✓ (pending Coordinator
  tf-plan + tf-apply-dev).

### Added (Phase 6.1.1)

- Phase 6.1.1: add CI IAM — serviceusage.serviceUsageConsumer + storage.admin (project)
  to the WIF CI principalSet for `gcloud builds submit`. serviceUsageConsumer resolves
  the "serviceusage.services.use permission" denied error; storage.admin resolves the
  "forbidden from accessing the bucket [sport-slot-dev-cloudbuild]" error on source
  tarball upload. Both added as google_project_iam_member in terraform/wif_iam.tf.
  Scope note: storage.admin at project level is broader than strictly necessary; a
  bucket-scoped binding on sport-slot-dev-cloudbuild is the tighter alternative —
  deferred to Phase 9 least-privilege hardening. ADR-0018 updated. Tracker: 6.1.1 ✓
  (pending Coordinator terraform apply).

### Fixed (Phase 6.2.6)

- Phase 6.2.6: gitignore gha-creds-*.json — google-github-actions/auth@v3 writes a
  credential file (gha-creds-<hash>.json) into the repo workspace root, which
  build_push.sh's git status --porcelain clean-tree check saw as an untracked file,
  causing "working tree not clean" error and aborting the deploy. Added gha-creds-*.json
  to .gitignore under the GCP/Firebase section. Tracker: 6.2.6 ✓.

### Fixed (Phase 6.2.5)

- Phase 6.2.5: bump CI Node 20 → 22 — pnpm v11 requires Node >=22.13 (uses node:sqlite
  builtin); CI pinned node-version: 20 caused "ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite".
  Changed all 3 node-version occurrences (pr-gates.yml:47, deploy.yml:40, deploy.yml:66).
  Added "engines": {"node": ">=22.13"} to frontend/package.json as single source of truth,
  mirroring the packageManager approach. Local Node v22.17.1 — no local issue.
  YAML valid; local: install OK · lint 0 errors · 43 tests passed · build OK.
  Clears Node-20 deprecation warning ahead of GitHub's Node-24 default. Tracker: 6.2.5 ✓.

### Fixed (Phase 6.2.4)

- Phase 6.2.4: fix pnpm version mismatch — CI pinned pnpm v9 but the project uses v11
  (allowBuilds syntax in pnpm-workspace.yaml, no packages field, is valid v11 and invalid
  v9). Added "packageManager": "pnpm@11.5.2" to frontend/package.json as the single source
  of truth; both workflows (pr-gates.yml, deploy.yml — 3 occurrences) now use
  pnpm/action-setup@v4 with package_json_file: frontend/package.json instead of
  hardcoded version: 9. Resolves "packages field missing or empty" in CI.
  Local: lint 0 errors · 43 tests passed · build OK. Tracker: 6.2.4 ✓.

### Fixed (Phase 6.2.2)

- Phase 6.2.2: fix non-hermetic test — test_validation_failed_includes_field_detail
  constructed a real Firestore client (failing in CI without ADC); now overrides the
  client dependency via dependency_overrides[get_firestore_client] = lambda: _prov_client()
  like all 20 sibling tests. Test is credential-free: passes with GOOGLE_APPLICATION_CREDENTIALS
  unset and GOOGLE_CLOUD_PROJECT="". Sibling scan: all 21 tests in test_tenant_config.py
  now have the override — zero remaining hermeticity risks. Tracker: 6.2.2 ✓.

### Fixed (Phase 6.2.1)

- Phase 6.2.1: Suppress 4 bandit B105 false positives (must_change_password Firestore field
  names in users.py + provisioning.py ×2, and WEAK_PASSWORD error code constant in
  error_codes.py) via per-line # nosec B105 with explanatory reason. B105 remains active
  elsewhere. CI backend gate now green: bandit 0 issues · ruff clean · 128 passed 91.56%
  coverage ≥ 90%. Tracker: 6.2.1 ✓.

### Added (Phase 6.2)

- Phase 6.2: GitHub Actions — pr-gates.yml (backend: ruff+bandit+pytest ≥90% coverage,
  frontend: lint+test+build, no GCP access on PRs by design) + deploy.yml (same gate suite
  on main for defense-in-depth, then keyless WIF auth + build/push backend via Cloud Build +
  gcloud run deploy + firebase deploy hosting on push to main). Deploy make targets
  (deploy_cloud_run.sh, deploy_hosting.sh) made CI-aware: interactive DEPLOY prompt skipped
  when $CI is set; manual experience unchanged. firebase-tools installed in deploy job
  (not pre-installed on runners, not in devDeps); uses WIF ADC — no interactive login needed.
  Coverage threshold 90% (measured 92% − 2% buffer per global rule). Tracker: 6.2 ✓
  (pipeline validated in 6.3).

### Added (Phase 6.1)

- Phase 6.1: WIF pool + provider activated as managed Terraform resources (imported from
  Phase-1 gcloud-created resources via IMPORT_6.1.md); data sources in wif.tf replaced by
  resource blocks; outputs.tf updated to reference resource addresses. Direct-WIF IAM bindings
  for CI deploy in wif_iam.tf: run.admin, artifactregistry.writer, cloudbuild.builds.editor,
  firebasehosting.admin + serviceAccountUser on sa-cloud-run (CI deploys as runtime SA) +
  serviceAccountUser on sa-cloud-build (flagged for Coordinator confirmation). ADR-0018 CI/CD
  security model: keyless direct WIF, repo+main-only attribute condition enforced at identity
  layer, Cloud Run deployed via gcloud (not Terraform) to avoid image-tag drift.
  Terraform fmt ✓ · validate ✓. Pending: Coordinator import + apply. Tracker: 6.1 ✓ (pending
  Coordinator import+apply).

### Added (Phase 5.6)

- Phase 5.6: Phase 5 retrospective (docs/retrospectives/phase-5.md — issue log, deferrals,
  validation quality note, carried-forward items). ADR-0014 email reconciled: §2 now names
  admin@sportbook.chandraailabs.com as the dev seed email (earlier drafts referenced
  "superadmin@…"). make reset-superadmin target + backend/scripts/reset_superadmin.py: dev-only
  one-command recovery for a lost superadmin password (NEWPW env var, refuses outside
  development). docs/roadmap.md created: phase status table, Phase 5 deferrals tracker,
  Phase 6–9 planned scope. PHASE 5 COMPLETE — Admin & Onboarding. Tracker: Phase 5 ✓.

### Added (Phase 5.5.2)

- Phase 5.5.2: Forced password change is now enforced globally via the route guards
  (`ProtectedRoute` + `TenantAdminRoute`), not just the Landing route — closes the bypass
  where reaching `/tenant/*`, `/bookings`, or `/facilities/*` directly (post-login nav,
  refresh, or direct URL) skipped the mandatory change entirely. New `usePasswordGate` hook
  fetches `/users/me` once (shared `["profile"]` query key, cached across all guards) and
  returns `{ mustChange, loading }`; platform admins excluded. `ForcePasswordChange`
  invalidates `["profile"]` on success before navigating to `/` to prevent a redirect loop
  from the stale cached flag. `/force-password` route remains un-gated. Landing simplified:
  `must_change_password` check removed (guard handles it before Landing renders) — only
  role-based routing remains. 43 frontend tests (+2: TenantAdminRoute password-gate tests).
  Build: 115 kB gzip (128 backend tests unchanged). Tracker: 5.5.2 ✓.

### Added (Phase 5.5.1)

- Phase 5.5.1: Fix forced-password-change routing for tenant_admin + shared `AppHeader` component.
  Bug fix: `enabled: !isAdmin && !isTenantAdmin` in Landing disabled the `/users/me` query for
  tenant_admin, causing `must_change_password` check to be skipped and routing directly to `/tenant`.
  Fixed by `enabled: !isAdmin` (runs for all non-platform-admin roles) with an `isLoading` gate
  before all redirects, ordering `must_change_password` check before the role-based redirect.
  New `AppHeader` component: logo + brand name (Link to "/") + optional children slot + user
  email·role badge + sign-out button. Adopted on all authenticated screens: Facilities, MyBookings,
  TenantDashboard, TenantFacilities, TenantBranding, TenantPolicies, TenantUsers, TenantList.
  41 frontend tests (+4: AppHeader×3, Landing regression guard×1). Build: 115 kB gzip
  (128 backend tests unchanged). Tracker: 5.5.1 ✓.

### Added (Phase 5.5b)

- Phase 5.5b: tenant user management UI (list active users, add, deactivate, reset password,
  bulk CSV import), admin-initiated password reset backend (ADR-0014 amendment — tenant-admin
  or platform-admin resets any user in their scope; returns temp_password once; sets
  must_change_password=true). Factored `CredentialDisplay` component with "Copied!" feedback
  shared by create/bulk/reset flows. Branding fix: GET `/tenants/{slug}/branding` now returns
  `brand_logo_url`; `TenantBranding` form pre-fills from current branding on mount (slug from
  JWT claim per ADR-0012 §2); logo renders in resident header via `getLastBranding()`.
  `flat_number` field hidden when role=tenant_admin on the Add User form (required only for
  resident). VALIDATION_FAILED 422 field detail (loc+msg) now surfaced in user-facing error
  messages. `ApiClientError` extended to carry the `detail` array. 37 frontend tests
  (128 backend tests, 92% coverage, 115 kB gzip). PHASE 5 FEATURE-COMPLETE. Tracker: 5.5b ✓.

### Added (Phase 5.5a)

- Phase 5.5a: tenant-admin UI — role-based landing (`TenantAdminRoute` → `/tenant`), dashboard
  with 4 nav cards, facilities management (catalog-based create/list/deactivate), branding form
  (brand name, primary/secondary hex color, logo URL), booking-policies form. `TenantAdminRoute`
  guards all `/tenant/*` routes; tenant_admin JWT claim redirects to `/tenant` at landing.
  `tenantAdminHooks.ts` wraps all tenant-config and facility API calls via TanStack Query.
  `TenantUsers` stubbed (Phase 5.5b). 7 new frontend tests (29 total). Build: 113 kB gzip.
  Tracker: 5.5a ✓.

### Added (Phase 5.4b)

- Phase 5.4b: tenant-admin config backend — PATCH `/tenant/branding` (hex color + http(s) URL
  validation, merge-into-map semantics), PATCH `/tenant/policies` (bounds: horizon≥1,
  buffer≥0, max_slots≥1, HH:MM time format), `/tenant/users` CRUD (POST/GET/DELETE) + bulk
  import POST `/tenant/users/bulk` (per-row report: created+temp_password or failed+reason,
  500-row cap). `flat_number` now optional for `tenant_admin` role (required for `resident`);
  `ProvisioningError(ApiError)` subclass separates expected from unexpected errors. Request
  validation 422 now includes a `"detail"` array with `loc` + `msg` per field. New
  `api/v1/tenant_config.py`; admin.py `deactivate_user` uses constructor-bound `caller_uid`.
  17 new tests (122 total, 91% coverage). Tenant-admin backend complete. Tracker: 5.4b ✓.

### Added (Phase 5.4a)

- Phase 5.4a: global facility catalog (seed + GET /facility-catalog), catalog-based tenant
  facility CRUD (POST/GET/PATCH/DELETE `/tenant/facilities`) replacing 3.2 free-form creation
  (ADR-0015). `seed_facility_catalog.py` seeds 7 types (badminton, tennis, swimming, gym,
  turf-football, table-tennis, basketball) and back-links legacy free-form facilities via
  sport-string migration. `POST /tenant/facilities` validates `facility_type_id` against
  catalog and copies `sport` from catalog doc. `DELETE /tenant/facilities/{id}` soft-deactivates
  (active=false). Removed free-form `POST /facilities` and `PATCH /facilities/{id}` (superseded).
  Removed orphaned `models/facility.py`. `firebase.json` firestore block added (indexes path
  wired). `make seed-facility-catalog` target added. 7 new tests (105 total, 90% coverage).
  ADR-0015 §1 amended: brand_logo_url is a URL field; Cloud Storage upload deferred to Phase 7.
  Tracker: 5.4a ✓.

### Fixed (Phase 5.3.1)

- Phase 5.3.1: fix — removed dev-tenant-slug pin from `_slug_from_host`; unrecognized
  hosts (localhost, *.web.app, *.run.app) now return None so the JWT tenant_slug claim
  is always authoritative (ADR-0012 §2 / ADR-0007). Previously `SPORTSLOT_DEV_TENANT_SLUG`
  silently overrode the JWT claim, breaking every non-default tenant in local dev.
  Removed `_DEV_HOSTS` (dependency.py) and `dev_tenant_slug` field (config.py); renamed
  `test_dev_override_allows_localhost_in_development` → `test_localhost_no_host_header_trusts_jwt`;
  added 3 regression guards (rvrg-on-localhost-allowed, demo-on-localhost-still-allowed,
  rvrg-subdomain-with-demo-claim-still-403). 102 tests, 90% coverage. Tracker: 5.3.1 ✓.

### Added (Phase 5.3)

- Phase 5.3: platform-admin UI — role-based routing (PlatformRoute guard), tenant list +
  create-tenant + create-user screens, one-time temp-password credential block with copy
  button ("shown only once" warning), forced password-change screen (ForcePasswordChange),
  admin error-catalog entries (6 new codes), Landing component with must_change_password
  gate (fetches /users/me post-login via TanStack Query; platform_admin → /admin redirect).
  7 test files, 22 tests. Build: 411 kB JS / 112 kB gzip. Tracker: 5.3 ✓.

### Fixed (Phase 5.2.1)

- Phase 5.2.1: fix — platform-admin tokens accepted on any host in DEV (ADR-0014
  route+role gating); admin-host segregation deferred to Phase 9 (charter exposure
  logged). Fixes superadmin lockout on localhost. Removed `is_admin_host` gate from
  `auth/dependency.py`; `require_platform_admin` is the sole authorization layer.
  Inverted test `test_platform_admin_on_any_host_allowed_adr0014`; added regression
  guard `test_platform_admin_on_localhost_allowed_regression_5221`. 99 tests, 90% coverage.
  Tracker: 5.2.1 ✓.

### Added (Phase 5.2)

- Phase 5.2: platform-admin backend provisioning — ADR-0017 (deletion/retention lifecycle,
  three-stage ACTIVE→INACTIVE→PURGED, user soft-delete + Firebase disable + cancel future
  bookings, self-deactivation forbidden), `require_platform_admin` dependency, 6 new error
  codes (TENANT_SLUG_TAKEN, INVALID_SLUG, USER_EMAIL_TAKEN, USER_NOT_FOUND,
  SELF_DEACTIVATION_FORBIDDEN, WEAK_PASSWORD), `UserProvisioningService` (create_user with
  tenant_slug lookup + AuditRepository + rollback guard, deactivate_user +
  _cancel_future_bookings), `PlatformRepository.create_tenant / get_tenant_by_slug /
  list_tenants` (collection_name guard removed to allow direct multi-collection access),
  `/api/v1/admin` router (POST /tenants, GET /tenants, POST /tenants/{id}/users,
  POST /tenants/{id}/users/bulk, DELETE /tenants/{id}/users/{uid}),
  POST /api/v1/users/me/change-password (clears must_change_password flag),
  seed_platform_admin.py + `make seed-platform-admin` (idempotent),
  composite Firestore index (bookings: uid+status+date for deactivation cancel-scan).
  13 new tests (98 total, 90% coverage). Tracker: 5.2 ✓.

### Added (Phase 5.1)

- Phase 5.1: ADR-0014 (admin architecture & identity — route gating, seeded superadmin,
  generate+force-change credentials), ADR-0015 (facility catalog → tenant instances),
  ADR-0016 (shared user provisioning, CSV bulk import). PHASE 5 IN PROGRESS.
  Tracker: 5.1 ✓.

### Fixed (Phase 4.6.1)

- Phase 4.6.1: fix — branding resolves on non-subdomain hosts (.web.app) via
  VITE_DEFAULT_TENANT_SLUG, and re-applies post-login from the JWT tenant_slug claim.
  Branding endpoint/data were correct; frontend slug resolution was the gap.
  Tracker: 4.6.1 ✓.

### Added (Phase 4.6)

- Phase 4.6: public per-tenant branding endpoint + CSS-variable application on app load,
  server-computed `cancellable` flag on /bookings/mine (reuses cancellation deadline logic —
  refactored into shared `_is_cancellable()` helper), eye-icon password toggle in sign-in,
  hide-cancel-when-closed (MyBookings shows "Cancellation closed" hint), Phase 4 retrospective,
  branding backfill in seed. PHASE 4 COMPLETE (custom domain deferred to Phase 7).
  Tracker: 4.6 ✓.

### Added (Phase 4.5a)

- Phase 4.5a: Firebase Hosting config (firebase.json rewrites /api/** → Cloud Run, SPA fallback),
  deploy_hosting.sh (Coordinator-run, guarded), X-Forwarded-Host-aware tenant cross-check
  (conditional host enforcement — recognized subdomains enforced, unrecognized hosts trust JWT
  claim; JWT remains authoritative per ADR-0007/ADR-0012 §2), Cloud Run direct ingress logged
  as accepted exposure in security charter (Phase 7 LB closure path documented). Tracker: 4.5a ✓.

### Added (Phase 4.4)

- Phase 4.4: my-bookings list + cancellation (dialog-level error handling, query invalidation
  reopens slots), proactive quota banner on availability page, sign-in show-password toggle.
  Booking dialog errors now surface in-dialog instead of closing dialog (fixes silent 409 UX).
  Tracker: 4.4 ✓.

### Added (Phase 4.3)

- Phase 4.3: ADR-0013 (error presentation/i18n — resolver chain, English catalog, fail-safe),
  TanStack Query booking hooks (useFacilities, useAvailability, useCreateBooking), facility list,
  availability grid with SlotGrid + IN_PROGRESS warning, booking confirm dialog with error
  catalog lookup. Tracker: 4.3 ✓.

### Added (Phase 4.2)

- Phase 4.2: Firebase Auth context (onIdTokenChanged, token-refresh-aware), tenant resolution
  (host subdomain + JWT claim cross-check), typed same-origin API client (apiFetch),
  sign-in page (email/password + Google), ProtectedRoute, Home page with mismatch warning.
  Tracker: 4.2 ✓.

### Added (Phase 4.1) — PHASE 4 IN PROGRESS

- Phase 4.1: ADR-0012 (hosting constraint findings — Firebase Hosting 20-subdomain cap, LB wildcard
  deferred to Phase 7; same-origin API rewrites; CSS-variable theming; Tailwind rejected) + Vite/TS
  strict/PWA scaffold with pnpm, TanStack Query, React Router, vitest + Testing Library. lint/test/build
  gates pass; bundle 209.50 kB / 68.33 kB gzip; PWA service worker generated.

### Fixed (Phase 3.6.1)

- 3.6.1: fix — cancelled bookings can be rebooked (status-aware supersede in transaction).

### Added (Phase 3.6) — PHASE 3 COMPLETE

- Phase 3.6: ADR-0011 synchronous Firestore audit trail, IN_PROGRESS slot marking + booking
  notice, concurrency proof script, Phase 3 retrospective. PHASE 3 COMPLETE
  (cloud redeploy pending Coordinator). Tracker: 3.6 ✓.

### Added (Phase 3.5)

- Phase 3.5: booking cancellation (self or tenant_admin, buffer-enforced on tenant clock,
  attribution fields) + GET /bookings/mine (cursor-paginated). Tracker: 3.5 ✓.

### Added (Phase 3.4)

- Phase 3.4: Memorystore Redis infra script (AUTH → Secret Manager), LockService (SET NX PX,
  owner-checked release, fail-closed), transactional booking creation (quota + deterministic-ID
  guards), Direct VPC egress wiring in deploy. Tracker: 3.4 ✓.

### Added (Phase 3.3)

- Phase 3.3: computed availability endpoint — pure-function slot matrix
  (past/booked/window/horizon), tenant-timezone rule evaluation, BookingRepository
  (read side), tenant timezone seeded.

### Added (Phase 3.2)

- Phase 3.2: PolicyService (override→default), Facility model + CRUD with require_role gate,
  seed v2 (tenant_admin user + tenant registry doc).

### Added (Phase 3.1)

- Phase 3.1: ADR-0009 (Redis slot locking), ADR-0010 (booking domain & policy resolution) accepted.

### Fixed (Phase 2.6.3)

- 2.6.3: retrospective investigation record corrected (omitted STEP 3 of 2.6.2;
  issue #11, audit-log findings).

### Fixed (Phase 2.7.1)

- Corrected fabricated documentation content (issue #10 in retrospective): charter
  had fictional run.allowedIngress override and omitted real allowedPolicyMemberDomains
  exception; retrospective omitted Cloud Run 404 investigation, protocol amendments,
  and issues #1/#6/#9; runbook omitted credential model; README omitted engineering
  method section. Root cause: session interruption + context compaction; Worker
  reconstructed instead of stopping. All five files replaced with verbatim content.

### Added (Phase 2.7) — PHASE 2 COMPLETE

- README.md rewritten: Phase 2 COMPLETE badge, Mermaid architecture diagram, ADR table
  (0001–0008), updated repo structure, security summary
- docs/retrospectives/phase-2.md: full Phase 2 retrospective (what went well, 7 issues
  log, key decisions, lessons learned, Phase 3 preview)
- docs/runbooks/local-development.md: replaced Phase 1 stub with comprehensive Phase 2
  backend runbook (GCP auth, dev server with PYTHONPATH, tests, seed, Docker, tenant
  routing, coordinator-only scripts, troubleshooting)
- docs/security/charter.md: v1.1 → v1.2; Org-Policy Exceptions section added
  (run.allowedIngress override documented with Phase 7 review date)

### Added (Phase 2.6) — Phase 2.6 COMPLETE

- Phase 2.6: Multi-stage Dockerfile (uv builder → slim non-root runtime); .dockerignore;
  guarded Coordinator scripts for AR/bucket setup (setup_build_infra.sh), Cloud Build push
  with git-SHA tags (build_push.sh), Cloud Run deploy min=0/max=2 sa-cloud-run (deploy_cloud_run.sh);
  Makefile: dev-env, run-dev, docker-build, docker-run, build-push, deploy-dev targets;
  config.py .env path anchored to backend/ (CWD-independent); .last_image_tag gitignored.

### Added (Phase 2.5) — Phase 2.5 COMPLETE

- Phase 2.5: GET /api/v1/users/me (TenantContext → UserProfileRepository → Firestore);
  slowapi in-memory rate limiting per ADR-0007 §5 — 429 in error envelope via middleware
  subclass (slowapi middleware bypasses app exception handlers); /healthz + /readyz exempt;
  guarded dev seed script (backend/scripts/seed_dev_user.py), Firebase token helper
  (scripts/get_dev_token.sh), Makefile seed-dev target, architecture gate test. 31 tests,
  coverage 89%.

### Added (Phase 2.4) — Phase 2.4 COMPLETE

- Phase 2.4: ADR-0008 (subcollection layout, permanent deny-all rules, repository contract);
  infrastructure/firestore.rules updated with ADR-0008 comment block + guarded deploy script;
  TenantRepository/PlatformRepository + UserProfile model. Coverage ≥80% (87%).

### Added (Phase 2.3) — Phase 2.3 COMPLETE

- Phase 2.3: FastAPI scaffold — app factory, request-ID middleware, error envelope + code
  registry, structlog with PII redaction, /healthz + /readyz, TenantContext auth dependency
  (ADR-0006/0007). Coverage ≥80% (93%).

### Added (Phase 2.2) — Phase 2.2 COMPLETE

- Phase 2.2: Security charter v1.1 committed to docs/security/charter.md (identity &
  credential model, ADR-0006/0007 alignment)

### Added (Phase 2.1) — Phase 2.1 COMPLETE

- ADR-0006: API Design Patterns accepted — URL path versioning (/api/v1/), UPPER_SNAKE
  error code registry, cursor-based pagination (offset prohibited), split liveness/readiness
  health probes outside versioned surface
- ADR-0007: Authentication & Authorization accepted — firebase-admin-only JWT verification
  (python-jose prohibited: CVE-2024-33663/CVE-2024-33664), custom claims as identity source of
  truth, accepted 1-hour staleness with selective revocation on SENSITIVE endpoints, no admin
  tenant bypass, phased rate limiting (slowapi → Redis → Cloud Armor)
- docs/adr/README.md: Phase 2 section added with index entries for ADR-0006 and ADR-0007

### Fixed
- verify_toolchain.sh exited with code 120 due to SIGPIPE when gcloud --version
  output was piped to `head -1`; `head` closed the pipe after line 1 and gcloud
  received SIGPIPE on subsequent writes — under `set -euo pipefail` this aborted
  the script mid-execution, skipping gcloud, Git, and gh CLI checks
- Replaced all `| head -1` patterns with `| sed -n '1p'` across Homebrew,
  Terraform, ShellCheck, gcloud, and gh CLI version checks; sed reads all input
  before producing output, eliminating SIGPIPE risk

### Added (Phase 1.4.3) — Phase 1 COMPLETE
- Makefile at repo root with 11 self-documenting commands (make help)
- scripts/install.sh — backend + frontend dependency installation
- scripts/tf-init.sh, tf-plan.sh — Terraform workflow helpers
- scripts/tf-apply-dev.sh — apply with single confirmation guardrail
- scripts/tf-destroy-dev.sh — destroy with double confirmation guardrail
- scripts/gcp-whoami.sh — show gcloud auth state + ADC status
- scripts/gcp-set-dev.sh — switch to sport-slot-dev project
- docs/adr/README.md — ADR index with status table for all 5 Phase 0 ADRs
- docs/adr/template.md — template for future ADRs
- docs/runbooks/phase-1-retrospective.md — lessons learned from Phase 1
- README.md updated: Phase 1 COMPLETE badge + Quick Start section
- Removed obsolete .gitkeep placeholders (5 files)
- All 7 new scripts ShellCheck clean

### Added (Phase 1.4.2)
- Documented existing GCP resources in Terraform (Option C — hybrid data sources + commented templates)
- terraform/apis.tf: 18 APIs (9 core + 9 operational) as locals + commented resource template
- terraform/iam.tf: 4 service accounts as data sources + commented resource templates with roles documented
- terraform/wif.tf: WIF pool + provider as data sources + commented resource/binding templates
- terraform/firestore.tf: Firestore documented via locals (no data source in provider v6) + commented resource
- terraform/outputs.tf: 12 outputs covering project, region, SA emails, WIF names, Firestore name/location
- Note: google_firestore_database data source absent from provider v6; using locals with known-stable values

### Added (Phase 1.4.1)
- terraform/ directory with module-ready flat structure (Option B+)
- terraform/backend.tf — remote state in gs://sport-slot-dev-tfstate (prefix: terraform/state)
- terraform/main.tf — Google + Google-beta providers pinned ~> 6.0
- terraform/variables.tf — input variables with validation (project_id, region, environment patterns)
- terraform/outputs.tf — basic variable pass-through outputs
- terraform/apis.tf, iam.tf, wif.tf, firestore.tf — empty placeholders for Phase 1.4.2 import
- terraform/terraform.tfvars.example — committed template for developer onboarding
- terraform/.terraform.lock.hcl — provider version pins (google + google-beta v6.50.0)
- .gitignore updated: scoped to terraform/ prefix, lock file explicitly NOT ignored

### Added (Phase 1.3.3)
- Firebase project enabled on sport-slot-dev (fixes G17 root cause from old SportBook postmortem)
- Firebase Web App "SportSlot Web (React PWA)" created (App ID: 1:707808711911:web:f16ca1570a30f4e5957e42)
- Web app config captured to infrastructure/firebase-web-config.json (local only, not committed)
- .gitignore patterns for Firebase config files (infrastructure/firebase-*.json)
- Email/Password and Google OAuth authentication providers enabled
- Firestore database created (Native Mode, asia-south1 / Mumbai)
- Deny-all security rules deployed via `firebase deploy --only firestore:rules`
- infrastructure/firestore.rules (deny-all baseline; tenant-aware rules added in Phase 2)
- infrastructure/firestore.indexes.json (empty — composite indexes added per query design in Phase 2)
- firebase.json and .firebaserc for Firebase CLI configuration
- sa-firebase-admin granted: roles/firebase.admin, roles/datastore.user, roles/iam.serviceAccountTokenCreator, roles/logging.logWriter
- sa-cloud-run granted roles/datastore.user for direct Firestore access
- sa-cloud-run can impersonate sa-firebase-admin via serviceAccountTokenCreator on SA resource
- infrastructure/iam-config.yaml: added authentication_strategy section documenting ADC pattern
- docs/runbooks/iam-setup.md: added ADC pattern explanation with code examples
- docs/runbooks/local-development.md: new runbook for developer onboarding

### Architecture Decisions Confirmed (Phase 1.3.3)
- Authentication uses Application Default Credentials (ADC) + Workload Identity Federation
- No static service account JSON keys generated (org policy iam.disableServiceAccountKeyCreation enforces this)
- Aligned with Google's "Secure by Default" policy and ADR-0004 5-layer defense-in-depth

### Added (Phase 1.3.2)
- 4 service accounts with least-privilege baseline roles:
  - sa-cloud-run (secretAccessor, logWriter, metricWriter, cloudtrace.agent)
  - sa-firebase-admin (placeholder — roles added in Phase 1.3.3)
  - sa-cloud-build (run.developer, artifactregistry.writer, logWriter + impersonation)
  - sa-monitoring (monitoring.editor, logWriter)
- Workload Identity Federation for GitHub Actions (no JSON keys)
- WIF restricted to main branch of chandranakkalakunta/sport-slot-reservation
- infrastructure/iam-config.yaml documenting IAM setup
- docs/runbooks/iam-setup.md
- .gitignore pattern for phase audit logs (scripts/phase-*.txt)

### Added (Phase 1.3.1)
- GCP project sport-slot-dev created under chandraailabs.com org
- Billing account 014A8C-586310-DE4575 linked
- 18 GCP APIs enabled (core infrastructure + operational)
- infrastructure/project-config.yaml documenting project setup
- docs/runbooks/gcp-project-setup.md

### Added
- Phase 1.2: Local toolchain installed and verified
- Python 3.12.13 via uv (alongside system 3.13)
- Project .venv created at repo root with Python 3.12
- Firebase CLI 15.19.1 reinstalled via pnpm (user-scope, ~/Library/pnpm)
- ShellCheck 0.11.0 installed via Homebrew
- Initial backend/pyproject.toml scaffolding
- Initial frontend/package.json scaffolding
- scripts/verify_toolchain.sh — all 13 checks passing
- Phase 1.1: Repository created with initial structure
- Phase 0 ADRs documented (ADR-0001 through ADR-0005)
- .gitignore covering Python, Node.js, Terraform, GCP, Firebase
- MIT License with Chandra AI Labs copyright
- README.md with project overview and architecture summary

## Phase History

### Phase 1 — Workspace Bootstrap (COMPLETE 2026-06-10)
- 1.1 GitHub + Local Workspace ✓
- 1.2 Local Toolchain (Python + Node) ✓
- 1.3 GCP Project + Firebase Initialization ✓
  - 1.3.1 GCP Project Foundation ✓
  - 1.3.2 Service Accounts + Workload Identity ✓
  - 1.3.3 Firebase + Firestore Initialization ✓
- 1.4 Terraform Foundation + Makefile + Docs ✓
  - 1.4.1 Terraform Foundation ✓
  - 1.4.2 Document Existing Resources ✓
  - 1.4.3 Makefile + Docs Finalization ✓

### Phase 2 — Backend API Foundation (COMPLETE 2026-06-12)
- 2.1 ADR-0006 + ADR-0007 (API design + auth decisions) ✓
- 2.2 Security charter v1.1 committed to docs/security/charter.md ✓
- 2.3 FastAPI scaffold + error envelope + TenantContext auth dependency ✓
- 2.4 Repository pattern + deny-all rules formalized + ADR-0008 ✓
- 2.5 /api/v1/users/me + slowapi rate limiting + dev seed ✓
- 2.6 Dockerfile + Cloud Run deploy scripts + papercut fixes ✓
- 2.7 Documentation closure: README, retrospective, runbook, charter v1.2 ✓

### Phase 3 — Booking Engine (IN PROGRESS)
- 3.1 ADR-0009 (Redis slot locking) + ADR-0010 (booking domain & policy) ✓
- 3.2 PolicyService + Facility CRUD + require_role + seed v2 ✓
- 3.3 Computed availability endpoint + BookingRepository (read side) + tenant timezone ✓

### Phase 0 — Foundation Decisions (complete)
- ADR-0001: Tech Stack & Software Versions
- ADR-0002: Database Technology Selection
- ADR-0003: Build Tooling Interface
- ADR-0004: Tenant Isolation Strategy
- ADR-0005: Cost Baseline & Budget Alerts
