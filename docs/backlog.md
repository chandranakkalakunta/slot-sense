# SlotSense — Project Backlog

Canonical record of tracked-but-not-scheduled work, per Three-Agent
Protocol §7.7. Organized by requirement-category block (who it serves),
not a flat list. The Strategist keeps this current: every deferral is
logged here the moment it's decided; every item is marked done with the
phase/PR that shipped it, and left in place as a requirement→phase
traceability record.

**Entry convention:** `[ID] status — one-line what & why. Blocker. Ref.`
Status ∈ `OPEN` · `BLOCKED` · `IN PROGRESS` · `✓ DONE — Phase X / PR #n`.

_Last updated: 2026-07-26_

**Phase 17 (Production Readiness) is build-complete** — all ten
2026-07-13 baseline audit findings resolved (PR-1a → PR-5c). The
timed DR drill / `slot-sense-test` environment build is the one
remaining item for formal phase close. See
`docs/retrospectives/phase-17-closeout.md`.

---

## Security & Compliance

- **SEC-01 · BLOCKED (pre-production)** — Confirm India DPDP cross-border
  transfer status before production. Voice audio processes outside India
  (STT asia-southeast1; TTS global); treated as notice-and-purpose, in the
  privacy notice + Phase 16 DPDP self-assessment. DPDP default-permits
  transfer absent a notified blacklist, but this was NOT re-verified vs.
  current rules — needs counsel / current check. Ref: ADR-0037 D5′.
- **VOICE-PROD-GATE · OPEN (before prod/resident-facing deploy) — HIGH** —
  The `SPORTSLOT_VOICE_ENABLED` flag was removed (2026-07-13); /agent/voice
  is now unconditionally live with no runtime gate. VOICE-HARDEN-01,
  VOICE-HARDEN-02, and SEC-01 must be resolved before the deploy pipeline
  targets a resident-facing prod/test environment.
- **PR-5-SECURITY · ✓ DONE — Phase 17 / PR #153, #154, #155** — Split
  by blast radius into PR-5a (low-risk, ✓ merged #153), PR-5b (WIF
  least-privilege, ✓ merged #154), and PR-5c (Armor enforce, option 2,
  ✓ merged #155). BinAuthz explicitly deferred to Phase 18 (ADR-0043,
  not PR-5 at all). Closes the last of the ten 2026-07-13 baseline
  audit findings (#7).
- **PR-5a-SECURITY · ✓ DONE — Phase 17 / PR #153** — Security headers
  middleware, charter CORS/headers claims corrected, Trivy image scan
  + pnpm audit added to CI (warn-only), legacy containerregistry API
  disabled, secret rotation policy documented. Ref: ADR-0043, PR-5a.
- **WIF-LEAST-PRIV · ✓ DONE — Phase 17 / PR #154** — GitHub WIF
  principal's project-level `roles/storage.admin` tightened to two
  bucket-scoped `storage.objectAdmin` grants (the only two buckets CI
  actually touches — Cloud Build source staging, frontend static
  assets); `roles/run.admin` tightened to `roles/run.developer` +
  a minimal custom role (`ciRunSetIamPolicy`, one permission:
  `run.services.setIamPolicy`) — verified live that run.developer
  alone lacks the permission `--allow-unauthenticated` needs, so a
  blind swap would have broken every deploy. `terraform/wif_iam.tf`.
  Ref: ADR-0043, PR-5b.
- **ARMOR-ENFORCE-GATE · ✓ RESOLVED — Phase 17 / PR #155** —
  Coordinator decision: option 2. The 14-day preview-log
  review (`docs/reviews/2026-07-21-armor-preview-log-review.md`)
  found 100% of preview-flagged-but-accepted requests (75/75) were
  legitimate `/api/v1/agent/voice` traffic false-positiving on the
  generic SQLi/XSS CRS rules against large voice-audio payload
  bodies. Resolution: a higher-priority `allow` rule
  (`priority = 900`) exempts that one path from WAF inspection, ahead
  of the SQLi (1000) and XSS (2000) rules, which then flip
  preview→enforce for every other path. `terraform/cloud_armor.tf`.
  Accepted residual tracked as `VOICE-INPUT-VALIDATION` below.
  `frontend_edge` confirmed intentional pass-through (structurally
  cannot hold WAF rules — `CLOUD_ARMOR_EDGE` type constraint).
  Ref: ADR-0043, PR-5c.
- **VOICE-INPUT-VALIDATION · OPEN (Phase 18 launch-gate, security)** —
  `/api/v1/agent/voice` is exempted from Cloud Armor's SQLi/XSS WAF
  inspection (ADR-0043 PR-5c, `ARMOR-ENFORCE-GATE`) because its
  base64 audio payloads are indistinguishable from attack signatures
  to a generic pattern-match WAF. The WAF is therefore NOT this
  path's SQLi/XSS defense — field-level input validation and safe
  sinks are. Audit the full voice→STT→agent path before Phase 18
  launch: confirm transcribed text is validated/sanitized before use,
  confirm every downstream sink is safe (Firestore is non-SQL, so
  classic SQLi doesn't apply, but injection-adjacent risks in
  query construction or Cloud Tasks payloads should be checked), and
  confirm the frontend escapes agent output before rendering (no
  `dangerouslySetInnerHTML`-style sinks on agent-produced text). This
  is the durable fix for the exempt path; the Armor exemption is an
  accepted interim posture, not the destination. Ref: ADR-0043 PR-5c.

## Platform Admin

- **PLATFORM-ADMIN-BOOTSTRAP · RESOLVED by PR-E (2026-07-24)** — A
  rebuilt/new environment had no *documented* admin-login path. The
  scripted admin-creation step (`backend/scripts/seed_platform_admin.py`:
  Firebase Admin SDK create user + role claim + Firestore admin doc,
  temp password printed once, never in TF/tfvars) already existed at
  drill time — the actual gaps were (a) the script resolved its target
  project from ambient ADC/gcloud config instead of an explicit flag,
  risking seeding the wrong environment, and (b) DR runbook Layer 6 had
  no reference to it. PR-E added a required `--project` argument (no
  ambient fallback) and a Layer 6 "First-time admin bootstrap"
  subsection. Originally found in DR drill Pass 1 (finding #3), now
  corrected there. Ref: `docs/runbooks/DRILL-pass1-report.md`,
  `docs/runbooks/disaster-recovery.md` Layer 6.

## Tenant Admin

- **TADM-01 · OPEN (part of VOICE-ML)** — Tenant-admin UI to configure up
  to 3 voice languages per tenant (ADR-0037 D3′). Storage field + read
  pattern + settings screen. Currently staged behind
  `resolve_tenant_voice_languages()` (hardcoded en-IN).
- **TADM-02 · OPEN (cosmetic)** — Bulk-import `reason` field inconsistency
  (message vs. code) between admin and tenant-admin endpoints.

## Resident

- **RES-01 · OPEN (cosmetic)** — FacilityAvailability page missing a
  facility-name header.

## Agent / AI Assistant

- **AGENT-ROUTER · OPEN (undecided)** — Whether to extend the deterministic
  pre-Vertex router (ADR-0026) from the 2 invoice tools to other agent
  tools. Constraint (1c-pre): any tool on the deterministic path MUST
  return resident-ready prose (list_my_bookings / get_my_preferences emit
  raw key=value + Markdown today, laundered only by Gemini Turn-2 — they'd
  leak if routed deterministically). Decide if their reliability matters.
- **VOICE-ML · BLOCKED** — Non-English voice (Telugu, Hindi, …). Blocked
  NOT by translation (Gemini translate is trivial) but by STT language
  auto-detection: capped at 3 langs, only at us/eu/global endpoints;
  chirp_2 (shipped) has no auto-detect; chirp_3 STT was withdrawn.
  Needs: pick detection mechanism → wire Gemini translate legs →
  real-speech Indic validation. Re-probe live first
  (scripts/voice/stt_model_probe.py, fixed — see VOICE-PROBE).
  After English E2E. Ref: ADR-0037 D3′.
- **VOICE-LEX · OPEN (part of VOICE-ML)** — Native-speaker review of the 6
  non-English confirm lexicons (ta/kn/ml/mr/gu/bn); te/hi by Coordinator.
  Fail-closed makes gaps safe, but each needs a pass before that language
  ships.
- **VOICE-BLOB-CLEANUP · OPEN (low)** — Reply-audio object URLs
  (base64→Blob→createObjectURL) are never revoked; older messages hold
  stale blob URLs on long sessions — a slow memory leak. Pre-existing
  (not introduced by barge-in). Add URL.revokeObjectURL on unmount /
  when audio is replaced. Frontend, MessageBubble/AudioReply.
- **VOICE-INPUT-LOCK · OPEN (low)** — Nothing prevents a voice/mic
  recording from starting while a prior /agent/query (text) or
  /agent/voice request is still in flight — a possible race. Consider
  disabling the mic while a turn is pending (the text input already
  disables via inputDisabled). Frontend.
## Infrastructure & Technical

- **IAM-TF-CODIFY · ✓ DONE — Phase 17 / PR #142** —
  The 4 baseline service accounts' roles (sa-cloud-run, sa-firebase-admin,
  sa-cloud-build, sa-monitoring) are documented only as commented-out
  resource templates in `terraform/iam.tf` (Phase 1.4.2 Option C) — the
  SAs themselves and every role binding were granted imperatively via
  `gcloud iam` in Phase 1.3.2/1.3.3 and are not real Terraform resources.
  Drifts/vanishes on infra rebuild. Separate from VOICE-IAM-TF (a single
  feature-scoped grant, now codified) — this covers the baseline set.
  Ref: ADR-0038 Layer 3. Closed by PR-1b (#142): SAs converted to managed
  resources, ~14 IAM bindings imported, Cloud Run service/Redis/Artifact
  Registry codified.
- **ROADMAP-STALE · ✓ DONE — Phase 17 / DOC-TRUTH** — `docs/roadmap.md`
  archived to `docs/archive/roadmap-2026-06.md`; a stub now points to
  `docs/backlog.md` (canonical) and `CHANGELOG.md` (phase progress).
- **PR-2-OBSERVABILITY · ✓ DONE — Phase 17 / PR #144–#147** —
  Uptime checks (edge + service path, later corrected to edge-only —
  #147), 4 alert policies (5xx rate, p95 latency, uptime failure,
  backup failure), 2 email+SMS notification channels, Error Reporting,
  voice/agent turn-counter metrics — all in `terraform/observability.tf`
  (ADR-0040). Ref: ADR-0040, PR-2.
- **PR-3-AVAILABILITY · ✓ DONE — Phase 17 / PR #148–#150** — maxScale
  2→10, HTTP startup + liveness probes on `/health`, "SlotSense Ops"
  dashboard — `terraform/cloud_run.tf` / `terraform/dashboard.tf`
  (ADR-0041 D15/D17). SLO defined at doc-level only (D14 — no
  Monitoring SLO API resources yet). Redis SPOF decision: BASIC tier
  accepted with triggers (see `REDIS-HA-TRIGGERS`). Ref: ADR-0041, PR-3.
- **PR-4-COST · ✓ DONE — Phase 17 / PR #151–#152** — Billing budget
  + five graduated thresholds (50/80/100/120% actual + 100% forecasted)
  per ADR-0005's ₹5K/mo dev ceiling, incl. the voice per-turn surface —
  `terraform/cost.tf` (new), `billingbudgets.googleapis.com` enabled via
  Terraform for the first time. Project-filtered to `sport-slot-dev`
  only. Alert-only by design (ADR-0042 D18) — no automated
  billing-disable/service-cap actuator. Final notification wiring is
  **Admin Email only** (#152 hotfix — the Budget API rejected the SMS
  channel; see ADR-0042's 2026-07-21 amendment). Ref: ADR-0042, PR-4.
- **TEST-PROJECT-BUDGET · OPEN (Phase 18)** — `slot-sense-test` has no
  billing budget yet because the project doesn't exist yet (ADR-0042
  D19 scopes PR-4's budget to `sport-slot-dev` only, by project filter,
  precisely so a future TEST project doesn't muddy the dev signal).
  Add an equivalent `google_billing_budget` once `slot-sense-test` is
  provisioned. Ref: ADR-0042 D19.
- **BACKUP-ALERT · IMPLEMENTED, PENDING APPLY/VALIDATION** — Alert on
  Firestore backup failure shipped as
  `google_monitoring_alert_policy.firestore_backup_failure` (PR-2,
  ADR-0040); log filter is defensive/provisional — validate at drill
  or first real failure. Ref: ADR-0038.
- **BACKUP-ABSENCE-ALERT · OPEN (low)** — The PR-2 backup alert detects
  *failed* backup operations, not a schedule that silently never runs.
  A "no successful backup in 36h" absence-detection condition is a
  named refinement, not shipped in PR-2. Ref: ADR-0040 D11.
- **ALERT-THRESHOLD-TUNE · OPEN (after SLO-LOAD-TEST)** — PR-2's alert
  thresholds (5xx > 5%/5min, p95 > 2500ms/15min) are provisional,
  set loose per the measured-gates principle. Tighten once
  SLO-LOAD-TEST produces real traffic distributions. Ref: ADR-0040.
- **AGENT-TURN-EVENT · OPEN (low)** — PR-2's `voice_turns` /
  `agent_text_turns` counters are built on Cloud Run platform request
  logs, not application logs, because `/agent/query` has no
  unconditional per-turn structured log event (unlike `/agent/voice`'s
  `voice_request_received`). Add one inside `run_agent`
  (tenant/latency/model dimensions) for per-tenant cost attribution
  when PR-4 wants it; platform request logs remain the volume-counter
  of record until then. Ref: ADR-0040 D12, PR-2.
- **AUTH-EXPORT-AUTO · OPEN (low)** — Automate weekly Firebase Auth
  export to GCS. Manual runbook procedure until then. Ref: ADR-0038
  Layer 6.
- **SLO-LOAD-TEST · OPEN (follow-on to PR-3)** — Load/perf test to
  validate the 99% SLO; the proof, not part of the PR-3 ADR. Also
  re-validates D15's probe/scale settings under real traffic and gates
  D14's SLO-API upgrade (Monitoring SLO / error-budget burn-rate
  resources, deferred until real traffic distributions exist). Ref:
  ADR-0041.
- **REDIS-HA-TRIGGERS · DEFERRED (ADR-0041 D16)** — BASIC tier Redis
  accepted as a documented residual; STANDARD_HA rejected at this
  stage (roughly doubles Redis cost against the ₹5K ceiling to protect
  an SLO that already tolerates ~7.3h/month, for a dev-stage system
  with no paying tenants). Revisit triggers (any one reopens the
  decision): first paying tenant / Phase 18 production launch gate; a
  measured Redis-attributed SLO breach or repeated Redis incidents;
  Memorystore maintenance windows observed impacting bookings. Ref:
  ADR-0041 D16.
- **PROJECT-ASSESSMENT · ✓ DONE — Phase 17 / third-party review
  2026-07-15 + Strategist validation 2026-07-16; artifacts:
  docs/reviews/**.
- **HARDENING-RESIDUALS · DEFERRED (ADR-0039)** — CMEK, VPC/NAT, admin
  MFA, pen test; revisit triggers in the ADR.
- **CI-AUDIT-RATCHET · OPEN (low)** — Flip pip-audit to blocking after
  first triage. Extended 2026-07-21 (PR-5a): also covers the new
  Trivy image scan and `pnpm audit` steps (both warn-only,
  `.github/workflows/pr-gates.yml`) — same measured-gates ratchet,
  one triage pass, all three flip together or as individually
  triaged. `pnpm audit --audit-level=high` already found 11 real
  findings (6 high, 1 critical) in frontend devDependencies
  (`eslint`'s `js-yaml` transitive chain) at PR-5a time — untriaged,
  noted for the ratchet pass, not fixed in PR-5a (out of scope: code/
  CI/docs only, no dependency upgrades). Ref: DOC-TRUTH, ADR-0043.
- **SMOKE-E2E · OPEN** — Playwright (or similar) deploy smoke: sign-in
  → availability → book → cancel. Ref: review P2.3.
- **CONTAINERREGISTRY-CLEANUP · PENDING COORDINATOR DISABLE** — Legacy
  `containerregistry.googleapis.com` API enabled, verified empty
  2026-07-21 (PR-5a, read-only: `gcloud container images list
  --repository=gcr.io/sport-slot-dev` → 404 NAME_UNKNOWN; backing
  bucket `gs://artifacts.sport-slot-dev.appspot.com` → 404 not found —
  two independent confirmations, no legacy images exist). Disable
  command prepared in the PR-5a PR body; not run (live mutation,
  Coordinator-only). Ref: ADR-0043, PR-5a.
- **SEC-HEADERS · ✓ DONE — pending merge, PR-5a** — Server-side
  security headers (HSTS, X-Content-Type-Options, X-Frame-Options,
  Referrer-Policy, baseline CSP) implemented:
  `SecurityHeadersMiddleware`
  (`backend/src/sport_slot/middleware/security_headers.py`), wired in
  `main.py`, verified by test
  (`test_security_headers_on_every_response`). Charter's
  CORS-strict-policy claim also audited: no `CORSMiddleware` exists
  or is needed — the load balancer's path-based routing (Phase 8b)
  puts frontend and API on the same origin per tenant subdomain, a
  stronger posture than a CORS policy would add. Not a gap; charter
  corrected to state this, no `CORS-REVIEW` backlog item needed (the
  real config isn't unsafe — it's absent by design). Ref: ADR-0043,
  PR-5a.
- **VOICE-HARDEN-01 · OPEN (hard gate before prod enablement)** — Enforce a
  30s max-utterance duration cap server-side (ADR-0036 D6). 1c ships only a
  2MB byte cap (~8-11 min at typical bitrates); STT's 60s sync limit is a
  loose backstop. Client-side 30s auto-stop is built (sub-phase 2 UX); this
  is the server-side enforcement.
- **VOICE-HARDEN-02 · OPEN (hard gate before prod enablement)** — Add a
  voice-specific (stricter) per-resident rate limit for /agent/voice
  reflecting its ≈₹1/turn cost (ADR-0036 D6). 1c inherits the generic
  per-user default (functional, not cost-tuned).
- **VOICE-IOS · OPEN (before iOS launch, not day-one)** — Verify & harden
  iOS Safari voice capture. Safari MediaRecorder emits MP4/AAC (backend STT
  auto-decode already tolerates it); sub-phase 2 attempts compatibility via
  mimeType feature-detection but is NOT tested on iOS devices. Needs real
  iOS device testing before iOS is a supported target. Android/desktop is
  primary.
- **INFRA-01 · BLOCKED (revisit if recurs)** — 13.6 CDN cache-fill
  0-byte-response bug. Reproduced once, root cause never confirmed.
- **INFRA-02 · OPEN (cosmetic)** — Firestore positional-filter deprecation
  warnings (`filter=` keyword vs. positional args) across the codebase.
- **OPS-RUNBOOK · OPEN (low)** — Config-var names (e.g.
  SPORTSLOT_VOICE_ENABLED) and required IAM roles live only in code
  docstrings; a deploy/runbook doc listing voice env vars + roles would
  have saved hours 2026-07-13.
- **AUTH-PROVIDER-CODIFY · RESOLVED by PR-F (2026-07-24)** — Environment
  Provisioning Spec GAP 2.2: `firebase projects:addfirebase` enables
  Firebase Auth but not any sign-in provider; without Email/Password
  turned on, `seed_platform_admin.py` fails with
  `CONFIGURATION_NOT_FOUND`. Previously a manual Console/CLI step with
  no runbook documentation. PR-F codifies it as
  `google_identity_platform_config.auth` in `terraform/auth.tf` —
  verified (provider binary inspection + live API check against
  sport-slot-dev, `subtype: FIREBASE_AUTH`) not to trigger a GCIP
  billing-tier upgrade. New environments get it for free on the
  bootstrap-group apply; sport-slot-dev (already has a live Config
  object) needs a one-time `terraform import` before its next apply.
  Ref: `docs/runbooks/disaster-recovery.md` §4.1 step 4.
- **SMS-CHANNEL-DECISION · RESOLVED by PR-F (2026-07-24)** — "Coordinator
  SMS" notification channel was a manual console pre-req;
  `observability.tf`'s `data "google_monitoring_notification_channel"`
  lookup on it failed the **entire plan** without it, blocking a
  scripted rebuild. Coordinator decision: new environments build
  email-only. PR-F gates the data source and `observability_channels`
  local behind `var.enable_sms_alerts` (default `false`); the channel
  can be created and attached later by setting the var true once it
  exists and is phone-verified. Legacy sport-slot-dev already has the
  channel — its gitignored tfvars must set `enable_sms_alerts = true`.
  Found in DR drill Pass 1 (finding #9). Ref:
  `docs/runbooks/DRILL-pass1-report.md`,
  `docs/runbooks/disaster-recovery.md` §4.1 step 5.
- **DRILL-BOOTSTRAP-SCRIPT · RESOLVED by PR-G (2026-07-25)** — Encoded
  the proven rebuild sequence (project create → billing link →
  bootstrap APIs → state bucket → `terraform init -backend-config` →
  firebase add → bootstrap-group apply → image build → secret
  population → main apply → corrective deploy → Firestore
  rules/indexes → frontend build+deploy → admin bootstrap →
  verification) into `scripts/drill-bootstrap.sh` — idempotent,
  `--start-phase N` resumable, `--dry-run` validates with zero live
  calls. A timed, uninterrupted run of that script is what produces the
  authoritative RTO measurement (still outstanding — see
  `DRILL-PASS-2`). Ref: `docs/runbooks/DRILL-pass1-report.md`,
  `docs/runbooks/disaster-recovery.md` §4.1.
- **DRILL-PASS-2 · IN PROGRESS (2026-07-25/26)** — Timed rebuild of a
  fresh dev environment (`slot-sense-dev-03`) via
  `scripts/drill-bootstrap.sh --yes`: provisioned to a running Cloud Run
  backend + deployed frontend + seeded admin in ~21 min, well inside the
  4h RTO (ADR-0038). Post-run verified: Cloud Run Ready/100% traffic,
  zero WARN+ logs, `terraform plan` = No changes, PITR + 7-day daily
  backups + delete-protection active, ingress internal-and-LB only.
  Remaining to close phase: DNS/cert cutover for
  `rvrg-dev.slotsense.chandraailabs.com` (Namecheap A record + permanent
  `_acme-challenge` CNAME → wildcard cert ACTIVE → `curl /health` == ok).
  DESCOPED per 2026-07-25 Coordinator decision: Firestore export/import
  and Firebase Auth export/import with hash params — there is NO data or
  user migration from sport-slot-dev; dev-03 is populated with fresh data
  manually. Ref: `docs/runbooks/provision-environment.md`,
  `docs/runbooks/DRILL-pass1-report.md`,
  `docs/runbooks/disaster-recovery.md` §1/§7/§8.
- **DNS-PATTERN-B · ✓ LOCKED (2026-07-25)** — Per-env host labels under
  the single `*.slotsense.chandraailabs.com` wildcard cert:
  `rvrg-dev` (dev-03), `rvrg-test` (test), `rvrg` (prod, no prefix). One
  wildcard cert covers all; no per-tenant/per-env certificate provisioning
  as the platform grows. Forward-binding for test/prod provisioning.
- **SPORT-SLOT-DEV-RETIRE · OPEN (Coordinator pace, no deadline)** —
  dev-03 replaces sport-slot-dev as the standing dev env (2026-07-25
  decision, replace-not-parallel). Retire only after dev-03 has enough
  manually-populated data that the dev workflow is fully back: then
  `gcloud projects delete sport-slot-dev`, remove its Namecheap DNS,
  prune the `dev` arm from `scripts/tf.sh`, and drop the hardcoded
  sport-slot-dev refs in `.github/workflows/deploy.yml` (ties to the
  per-env CI wiring job / `CI-DEPLOY-CLOUD-RUN-DEFAULTS-ASYMMETRY`).
- **TF-SH-REGISTRY-DEV-03 · ✓ DONE — Phase 17 / PR #169** —
  `scripts/tf.sh` registers `dev-03`; the stale `dev-01` arm (deleted
  project, local var-file removed) was pruned in the same change. The
  `dev`/sport-slot-dev arm retained until SPORT-SLOT-DEV-RETIRE.
- **CLOUD-RUN-WORKER-URL-COMPUTED · OPEN** — `terraform/cloud_run.tf`
  (~line 139) hardcodes `SPORTSLOT_WORKER_BASE_URL` to sport-slot-dev's
  live *.run.app URL. `env` is in `lifecycle.ignore_changes`, so
  post-create drift is invisible; CI's `deploy_cloud_run.sh` corrects
  the value on every deploy. But a bare `terraform apply` on a
  fresh project bakes in the WRONG URL for the initial revision —
  which is exactly why `scripts/drill-bootstrap.sh` Phase 6b (PR-G)
  exists as the interim. Proper fix: initialize to empty and let
  `deploy_cloud_run.sh` own the value exclusively, or compute it
  from `google_cloud_run_v2_service.sport_slot_api.uri` on a
  second-phase apply. Logged per §4.13 (Phase 6b is interim; root
  cause named). Ref: `scripts/drill-bootstrap.sh` phase6/6b,
  `terraform/cloud_run.tf`.
- **BOOTSTRAP-GROUP-SA-IAM-CLOSURE · RESOLVED by PR-I (2026-07-25)** —
  drill-bootstrap.sh Phase 3's -target list did not include
  google_service_account.cloud_build or its IAM bindings.
  Phase 4's build_push.sh subsequently failed with "Unknown
  service account" and then 403 on storage.objects.get. PR-I expands
  the target list to 12 resources covering the full closure. Root
  cause: scripts/setup_build_infra.sh (retired in same PR) had
  granted the missing bucket IAM imperatively against sport-slot-dev,
  never codified. Ref: PR-I.
- **SETUP-BUILD-INFRA-RETIRED · RESOLVED by PR-I (2026-07-25)** —
  scripts/setup_build_infra.sh (hardcoded PROJECT="sport-slot-dev")
  was the sole holder of sa-cloud-build's staging bucket IAM. PR-I
  codifies that binding into iam.tf as
  google_storage_bucket_iam_member.cloud_build_staging_object_admin
  and deletes the script. Other actions were already codified.
- **BUILD-PUSH-SILENT-PROJECT-DEFAULT · RESOLVED by PR-I (2026-07-25)** —
  scripts/build_push.sh defaulted PROJECT to "sport-slot-dev" when
  SLOTSENSE_PROJECT was unset, allowing accidental invocation against
  production. Fixed to hard-fail on missing env var.
- **ADC-PREFLIGHT-CHECK · RESOLVED by PR-I (2026-07-25)** — Phase 1's
  ADC set-quota-project warned-and-continued on failure, but ADC
  failure guarantees terraform init fails on the next line. PR-I adds
  Phase 0 preflight (gcloud auth application-default
  print-access-token) that hard-fails with clear instructions.
  Instance of §5.22.
- **API-PROPAGATION-WAIT · RESOLVED by PR-I (2026-07-25)** — Phase 3's
  single -target apply enabled Google APIs and then immediately
  consumed them in the same run, hitting API propagation lag as
  SERVICE_DISABLED errors. PR-I splits Phase 3 into 3a (APIs only) +
  60s sleep + 3b (resources). A cleaner Terraform-native fix is
  deferred — see TERRAFORM-API-PROPAGATION-TIME-SLEEP below.
- **TERRAFORM-API-PROPAGATION-TIME-SLEEP · OPEN** — the Phase 3a/3b
  split in drill-bootstrap.sh (PR-I) is a script-level workaround for
  a Terraform-level race: any resource creation that consumes an API
  immediately after google_project_service.enabled_apis enables it
  can race. Proper fix is a time_sleep resource in terraform/ gating
  all API-consuming resources on propagation completion. Deferred
  because it affects every apply (including production CI), not just
  fresh-project bootstrap.
- **PROVISIONING-OPERATOR-CARD · RESOLVED by PR-I (2026-07-25)** —
  docs/runbooks/provision-environment.md authored — one-page operator
  card with preflight commands (expected outputs), the two-command
  run, "Known failures" section covering the four propagation-family
  issues from the dev-02 drill with one-line fixes, and post-run
  manual tail (manifest handling, DNS records for Pattern B labels
  rvrg-dev/rvrg-test/rvrg, cert wait, tf.sh registry). Aimed at
  operator with no SlotSense context. Technical reference remains
  disaster-recovery.md.
- **BOOTSTRAP-VERIFICATION-INCLUDES-DEPENDENCY-CLOSURE · RESOLVED by
  protocol v3.9 (2026-07-25)** — the pattern of naming
  resources/bindings/behaviours from memory instead of reading the
  .tf files directly is captured in protocol v3.9 §4.14 (Read Before
  You Recommend) and §0.1 item 13. The protocol update is out-of-band
  with slot-sense repo and is not part of PR-I; referenced here for
  traceability.
- **PHASE-8-SILENT-EXIT · RESOLVED by PR-J (2026-07-25)** — Phase 8's
  `gcloud logging read | wc -l` pipeline and the `terraform plan
  -detailed-exitcode` check could die silently under `set -euo
  pipefail` on a transient failure (auth expiry mid-run, logging API
  not yet queryable on a freshly created project, network hiccup),
  skipping Phase 9 entirely. On dev-03 (2026-07-25) this left the
  environment built but without the bootstrap-output manifest. PR-J
  captures both commands' exit statuses separately, treats transient
  failures as WARN-and-continue, and moves the phase8 fail decision to
  `main()` so Phase 9 always runs once Phase 8 is entered. Ref:
  `scripts/drill-bootstrap.sh` phase8/main.
- **PHASE-0-FIREBASE-PREFLIGHT · RESOLVED by PR-J (2026-07-25)** —
  PR-I's Phase 0 preflight checked gcloud ADC only. Firebase CLI
  tokens expire faster (~1h idle) and were not checked, killing
  Phase 7's `firebase deploy` mid-run on the dev-03 drill. PR-J adds
  a `firebase projects:list` preflight in `main()` alongside the ADC
  check, hard-failing with a `firebase login --reauth` instruction.
  Ref: `scripts/drill-bootstrap.sh` main, `docs/runbooks/
  provision-environment.md`.
- **PHASE-2-STDOUT-MATCH-BRITTLE · RESOLVED by PR-J (2026-07-25)** —
  Phase 2's `firebase projects:addfirebase` success check
  pattern-matched CLI stdout wording ("already|success|Firebase
  resources"), which is unstable across firebase-tools versions — the
  WARNING fired on dev-03 despite Firebase being correctly enabled.
  PR-J replaces it with a ground-truth `firebase projects:list` check
  for the project ID. Ref: `scripts/drill-bootstrap.sh` phase2.
- **BUDGET-CEILING-PER-ENV · RESOLVED by PR-J (2026-07-25)** —
  `terraform/cost.tf`'s `google_billing_budget.slotsense_dev_ceiling`
  hardcoded `display_name`/`amount` to dev-scale (₹5,000, "SlotSense
  dev ceiling") regardless of which environment it was applied to — a
  non-drill config gap that would have silently bitten prod. PR-J adds
  `local.budget_amounts_inr` / `local.budget_display_names` maps keyed
  by `var.environment`; prod values are placeholders pending Coordinator
  confirmation (see the `TODO(prod)` comment in `cost.tf`). Resource
  address unchanged (no destroy/recreate). Ref: `terraform/cost.tf`.
- **CI-DEPLOY-BROKEN · RESOLVED by PR-K (2026-07-25)** — PR-I's
  removal of scripts/build_push.sh's SLOTSENSE_PROJECT:-
  sport-slot-dev default (a legitimate safety fix) broke
  .github/workflows/deploy.yml's build-push step, which relied
  on that default. Two workflow runs failed on main (30164897492
  for PR-I merge, 30167637066 for PR-J merge). PR-K adds the
  three required env vars (SLOTSENSE_PROJECT, SLOTSENSE_REGION,
  SLOTSENSE_ARTIFACT_REPO) explicitly to the build-push step,
  hardcoded to sport-slot-dev pending the larger per-env CI
  wiring job. Root cause: Strategist proposed the PR-I change
  without reading deploy.yml first — §4.13 miss, v3.9 §4.14
  violation. Ref: .github/workflows/deploy.yml build-push step.
- **CI-DEPLOY-CLOUD-RUN-DEFAULTS-ASYMMETRY · OPEN** — after PR-K,
  scripts/build_push.sh hard-fails on missing SLOTSENSE_PROJECT
  (PR-I) but scripts/deploy_cloud_run.sh still uses
  SLOTSENSE_PROJECT:-sport-slot-dev (default). Same
  silent-defaulting-to-production hazard PR-I aimed to close,
  just in a different script. Should be tightened when the
  larger per-env CI wiring job runs. Ref:
  scripts/deploy_cloud_run.sh lines 5-6.

---

## Completed (traceability record)

- **VOICE-1a · ✓ DONE — Phase Voice / PR #128** — Deterministic fail-closed
  confirm/deny guard, 9-language seed lexicon (data/logic split).
- **VOICE-1b · ✓ DONE — Phase Voice / PR #129** — STT ingestion + language
  detection; chirp_2 @ asia-southeast1, single-code English-first.
  Ref: ADR-0036, ADR-0037.
- **VOICE-1c · ✓ DONE — Phase Voice / PR #131** — /agent/voice endpoint,
  English-only pipeline (STT → confirm-guard | agent → TTS). Feature flag
  (SPORTSLOT_VOICE_ENABLED). Ref: ADR-0036, ADR-0037.
- **AGENT-INVOICE-FMT · ✓ DONE — Phase Voice/1c-pre / PR #130** —
  Professional prose for agent invoice replies (was raw key=value);
  presentation-only, TTS-safe.
- **AGENT-UX-01 · ✓ DONE — Phase Voice / PR #132** — Up-arrow recalls the
  previous user message for edit/resend. Enhanced to shell-style
  multi-level history (walk back/forward through all prior messages,
  draft-restore) in AGENT-UX-01b, PR #140.
- **AGENT-UX-02 · ✓ DONE — Phase Voice / PR #132** — `/clear` slash command
  clears thread + session state (UI-only).
- **VOICE-2 · ✓ DONE — Phase Voice / PR #132** — Mic capture + playback UI;
  spoken-confirm routing; auto-play with fallback.
- **VOICE-LOGGING · ✓ DONE — Phase Voice / PR #134** — Fixed structlog
  event→message rendering (EventRenamer) so structured logs are visible in
  Cloud Logging (was a project-wide prod-logging bug); added voice-path
  instrumentation. Permanent, keep.
- **VOICE-STT-403 · ✓ DONE — 2026-07-13 (imperative; see VOICE-IAM-TF to
  codify)** — Granted roles/speech.client to sa-cloud-run@; voice now
  transcribes end-to-end. Full round-trip working.
- **VOICE-IAM-TF · ✓ DONE — infra/voice-speech-iam (terraform/voice_stt.tf)**
  — Codified the imperative roles/speech.client grant (VOICE-STT-403) as
  a real `google_project_iam_member` resource, matching the
  invoice_export.tf / cloud_tasks.tf pattern. Import/plan/apply is
  Coordinator-run and not yet applied as of PR open — see PR for the
  exact commands.
- **AGENT-MD-TTS · ✓ DONE — Phase Voice / PR #135** — Markdown stripped from
  agent replies (`services/agent/text_format.to_plain_text`), applied once
  at the `run_agent` / `run_agent_confirm` boundary so both `/agent/query`
  and `/agent/voice` get clean prose. Formatting-only.
- **VOICE-BARGE-IN · ✓ DONE — Phase Voice / PR #138** — User takes
  priority: starting a recording now stops any in-progress TTS reply
  playback immediately (auto-played or fallback-button-resumed).
  Frontend-only; `isRecording` flows `MessageInput` → `Assistant` →
  `MessageThread` → `MessageBubble`'s `AudioReply`, which pauses its own
  `<audio>` ref on the rising edge.
- **VOICE-PROBE · ✓ DONE — Phase Voice / PR #139** — Fixed
  `scripts/voice/stt_model_probe.py`: replaced the 1b 9-language matrix
  (always 400s, API caps at 3 codes) with a case matrix that validates
  the shipped config first (chirp_2 @ asia-southeast1, en-IN only) plus
  regional-reachability and future-VOICE-ML cases, all ≤3 codes; missing
  --audio (including the default, gitignored fixture) now prints clear
  guidance instead of a bare "file not found". `resources/voice_fixtures/
  .gitkeep` already existed (PR #129) — nothing to add there.
