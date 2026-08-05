# Environment Power Control (ADR-0047) — FinOps sleep/wake support
#
# Nightly disable + manual env-power.sh need Redis create/delete, Cloud Run
# scale, scheduler pause/resume, uptime path patch, secret version add, and
# a small GCS state bucket. CI WIF principal already has run.developer +
# redis.viewer; this file adds the extra roles and the state bucket.
#
# Coordinator: terraform apply per env after merge so nightly GHA can act.

resource "google_storage_bucket" "env_power" {
  name                        = "${var.project_id}-env-power"
  project                     = var.project_id
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  force_destroy               = true

  labels = var.default_labels

  versioning {
    enabled = false
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_storage_bucket_iam_member" "ci_env_power_object_admin" {
  bucket = google_storage_bucket.env_power.name
  role   = "roles/storage.objectAdmin"
  member = local.github_principal_set
}

# Create/delete Memorystore for sleep/wake (viewer already in wif_iam.tf).
resource "google_project_iam_member" "ci_redis_admin" {
  project = var.project_id
  role    = "roles/redis.admin"
  member  = local.github_principal_set
}

resource "google_project_iam_member" "ci_cloudscheduler_admin" {
  project = var.project_id
  role    = "roles/cloudscheduler.admin"
  member  = local.github_principal_set
}

# Uptime check path soft-pause via Monitoring API (ADR-0047).
resource "google_project_iam_member" "ci_monitoring_uptime_editor" {
  project = var.project_id
  role    = "roles/monitoring.uptimeCheckConfigEditor"
  member  = local.github_principal_set
}

# Refresh redis-auth secret version on enable.
resource "google_project_iam_member" "ci_secretmanager_version_adder" {
  project = var.project_id
  role    = "roles/secretmanager.secretVersionManager"
  member  = local.github_principal_set
}
