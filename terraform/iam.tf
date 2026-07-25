# IAM Configuration — Service Accounts and Bindings
#
# ═══════════════════════════════════════════════════════════════
# ADR-0038 Layer 3 (PR-1b): SAs codified as managed resources
# ═══════════════════════════════════════════════════════════════
#
# The 4 service accounts below were originally created via `gcloud
# iam` in Phase 1.3.2 and granted roles incrementally through Phase
# 1.3.3. They are now imported as managed resources so that
# `terraform apply` is a credible from-scratch rebuild path.
#
# sa-scheduler-invoker and sa-tasks-invoker are managed elsewhere
# (cloud_scheduler.tf / cloud_tasks.tf) — not touched here.

# sa-cloud-run: Runtime SA for Cloud Run services
resource "google_service_account" "cloud_run" {
  account_id   = "sa-cloud-run"
  display_name = "SportBook Cloud Run Runtime"
  description  = "Runtime SA for Cloud Run services (backend + frontend)"
  project      = var.project_id
}
#
# Roles granted (Phase 1.3.2 + 1.3.3):
#   - roles/secretmanager.secretAccessor
#   - roles/logging.logWriter
#   - roles/monitoring.metricWriter
#   - roles/cloudtrace.agent
#   - roles/datastore.user           (added Phase 1.3.3)
#   - roles/aiplatform.user
#   - roles/firebaseauth.admin
#   - roles/speech.client            (already codified — voice_stt.tf)
#
# Impersonation: sa-cloud-run can impersonate sa-firebase-admin
#   (serviceAccountTokenCreator binding on sa-firebase-admin SA resource)

# sa-firebase-admin: Firebase Admin SDK operations
resource "google_service_account" "firebase_admin" {
  account_id   = "sa-firebase-admin"
  display_name = "SportBook Firebase Admin"
  description  = "Firebase Admin SDK operations (JWT verify, user mgmt)"
  project      = var.project_id
}
#
# Roles granted (Phase 1.3.3):
#   - roles/firebase.admin
#   - roles/datastore.user
#   - roles/iam.serviceAccountTokenCreator
#   - roles/logging.logWriter
#   - roles/serviceusage.serviceUsageConsumer (already codified — wif_iam.tf)

# sa-cloud-build: CI/CD via GitHub Actions WIF
resource "google_service_account" "cloud_build" {
  account_id   = "sa-cloud-build"
  display_name = "SportBook Cloud Build (CI/CD)"
  description  = "CI/CD deployments from GitHub Actions via WIF"
  project      = var.project_id
}
#
# Roles granted (Phase 1.3.2):
#   - roles/run.developer
#   - roles/artifactregistry.writer
#   - roles/logging.logWriter
#
# Impersonation: sa-cloud-build impersonates sa-cloud-run for deploys
# WIF binding: GitHub Actions impersonates sa-cloud-build (see wif.tf)

# sa-monitoring: Observability tools
resource "google_service_account" "monitoring" {
  account_id   = "sa-monitoring"
  display_name = "SportBook Observability"
  description  = "Cloud Monitoring dashboards, alerts, and metrics"
  project      = var.project_id
}
#
# Roles granted (Phase 1.3.2):
#   - roles/monitoring.editor
#   - roles/logging.logWriter

# ─── PROJECT-LEVEL IAM BINDINGS (D8 — Coordinator-approved scope) ───
#
# Codifies ONLY the 16 project-level bindings belonging to the six
# custom SAs, verified against the live policy (2026-07-16) in
# Step 1 of PR-1b. One resource per binding (§4.11 audit-trail
# style) — no for_each/dynamic collapsing.
#
# EXCLUDED (D8): the 3 bindings on firebase-adminsdk-fbsvc@ are
# Firebase-provisioned (created automatically when Firebase is
# enabled on the project, not by any human/IAM script) and are
# intentionally NOT codified here:
#   - roles/firebase.sdkAdminServiceAgent
#   - roles/firebaseauth.admin
#   - roles/iam.serviceAccountTokenCreator
# See docs/runbooks/disaster-recovery.md "Managed vs excluded
# inventory" appendix for the full exclusions list.
#
# Already codified elsewhere — NOT duplicated here:
#   - sa-cloud-run: roles/speech.client (voice_stt.tf)
#   - sa-firebase-admin: roles/serviceusage.serviceUsageConsumer (wif_iam.tf)
#   - all ci_* WIF bindings (wif_iam.tf, wif.tf)

# sa-cloud-run (7 bindings)
resource "google_project_iam_member" "cloud_run_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_cloudtrace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_datastore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_firebaseauth_admin" {
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_logging_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_secretmanager_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

# sa-cloud-build (3 bindings)
resource "google_project_iam_member" "cloud_build_artifactregistry_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cloud_build.email}"
}

resource "google_project_iam_member" "cloud_build_logging_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_build.email}"
}

resource "google_project_iam_member" "cloud_build_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.cloud_build.email}"
}

# sa-firebase-admin (4 bindings)
resource "google_project_iam_member" "firebase_admin_datastore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.firebase_admin.email}"
}

resource "google_project_iam_member" "firebase_admin_firebase_admin" {
  project = var.project_id
  role    = "roles/firebase.admin"
  member  = "serviceAccount:${google_service_account.firebase_admin.email}"
}

resource "google_project_iam_member" "firebase_admin_iam_service_account_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.firebase_admin.email}"
}

resource "google_project_iam_member" "firebase_admin_logging_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.firebase_admin.email}"
}

# sa-monitoring (2 bindings)
resource "google_project_iam_member" "monitoring_logging_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.monitoring.email}"
}

resource "google_project_iam_member" "monitoring_monitoring_editor" {
  project = var.project_id
  role    = "roles/monitoring.editor"
  member  = "serviceAccount:${google_service_account.monitoring.email}"
}

resource "google_project_iam_member" "compute_sa_cloudbuild_builder" {
  project    = var.project_id
  role       = "roles/cloudbuild.builds.builder"
  member     = "serviceAccount:${var.project_number}-compute@developer.gserviceaccount.com"
  depends_on = [google_project_service.enabled_apis]
}

# sa-cloud-build needs bucket-level storage.objectAdmin on the
# Cloud Build staging bucket to read source tarballs its own
# gcloud builds submit uploads. Historically granted imperatively
# by scripts/setup_build_infra.sh (hardcoded to sport-slot-dev,
# never codified) — a fresh project rebuild fails at
# build_push.sh Phase 4 without this. Codified here so a bare
# terraform apply produces a complete, working project.
# DR drill dev-02 finding (2026-07-25); setup_build_infra.sh
# retired in the same PR.
resource "google_storage_bucket_iam_member" "cloud_build_staging_object_admin" {
  bucket     = google_storage_bucket.cloudbuild_staging.name
  role       = "roles/storage.objectAdmin"
  member     = "serviceAccount:${google_service_account.cloud_build.email}"
  depends_on = [google_storage_bucket.cloudbuild_staging]
}
