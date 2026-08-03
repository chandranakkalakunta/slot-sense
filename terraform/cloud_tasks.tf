# Cloud Tasks Notification Pipeline — Phase 7.1.2
#
# Async email delivery (ADR-0019 Decisions 2-4). The Cloud Run app
# (sa-cloud-run) enqueues HTTP tasks targeting the worker endpoint
# POST /internal/tasks/notify; Cloud Tasks delivers them with an OIDC
# token minted for a dedicated invoker SA, which the worker endpoint
# verifies (auth/tasks_auth.py). cloudtasks.googleapis.com is already
# enabled — see apis.tf's operational_apis list (enabled via gcloud,
# Phase 1.3.1) — no API-enablement resource needed here.

resource "google_cloud_tasks_queue" "notifications" {
  name     = "notifications"
  project  = var.project_id
  location = var.region

  retry_config {
    max_attempts = 5
  }

  # Resend's free-tier cap is 100 emails/day; a modest dispatch rate
  # avoids bursting through that cap on any retry storm.
  rate_limits {
    max_dispatches_per_second = 5
    max_concurrent_dispatches = 5
  }
}

# Dedicated identity for Cloud Tasks' OIDC tokens — kept separate from
# sa-cloud-run so the worker endpoint can verify "caller is exactly
# this narrow SA" instead of trusting the broad runtime identity.
# Net-new SA (unlike the 4 SAs in iam.tf, which already exist via
# gcloud and are only referenced as data sources): Terraform creates
# this one.
resource "google_service_account" "tasks_invoker" {
  account_id   = "sa-tasks-invoker"
  display_name = "Cloud Tasks OIDC invoker for notification worker"
  project      = var.project_id
}

# The Cloud Run service (sport-slot-api) is gcloud-deployed, not
# Terraform-managed (ADR-0018) — grant run.invoker by service
# name/location rather than a managed resource reference.
resource "google_cloud_run_service_iam_member" "tasks_invoker_run_invoker" {
  project  = var.project_id
  location = var.region
  service  = "sport-slot-api"
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.tasks_invoker.email}"
}

# sa-cloud-run (the running app) is the identity that enqueues tasks.
# Queue-scoped, not project-scoped — sa-cloud-run has no reason to
# enqueue into any other queue.
resource "google_cloud_tasks_queue_iam_member" "cloud_run_tasks_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.notifications.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.cloud_run.email}"
}

# Cloud Tasks requires the enqueuing caller to be able to act as the
# OIDC SA it's asked to stamp onto the task (iam.serviceAccounts.actAs
# is bundled into roles/iam.serviceAccountUser). Scoped to the
# tasks_invoker SA resource only, not project-wide.
resource "google_service_account_iam_member" "cloud_run_act_as_tasks_invoker" {
  service_account_id = google_service_account.tasks_invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloud_run.email}"
}

# Resend API key secret access (ADR-0019 Decision 4). Secret
# "resend-api-key" already exists (Coordinator-created, version 4
# enabled) — this grants read access only; the secret itself is not
# managed here.
resource "google_secret_manager_secret_iam_member" "cloud_run_resend_secret_accessor" {
  project   = var.project_id
  secret_id = "resend-api-key"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run.email}"
}

# Redis AUTH secret — same pattern as resend. Project-level secretAccessor
# alone can race Cloud Run create on greenfield apply (IAM not yet visible
# to the Run control plane → SECRETS_ACCESS_CHECK_FAILED → service tainted).
# Secret-level binding + depends_on on the service closes that race.
resource "google_secret_manager_secret_iam_member" "cloud_run_redis_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.redis_auth.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run.email}"
}
