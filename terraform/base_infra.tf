# Base Infrastructure — Memorystore Redis + Artifact Registry
# (ADR-0038 Layer 3, PR-1b)
#
# Both resources were created imperatively (`gcloud redis instances
# create`, `gcloud artifacts repositories create`) and are absent
# from state. Authored field-for-field from the 2026-07-16 live
# describe output captured in PR-1b Step 1 so import produces a
# clean plan.

resource "google_redis_instance" "sport_slot_redis" {
  name           = "sport-slot-redis"
  project        = var.project_id
  region         = var.region
  location_id    = "asia-south1-c"
  tier           = "BASIC"
  memory_size_gb = 1
  redis_version  = "REDIS_7_0"

  authorized_network      = "projects/${var.project_id}/global/networks/default"
  connect_mode            = "DIRECT_PEERING"
  auth_enabled            = true
  transit_encryption_mode = "DISABLED"

  persistence_config {
    persistence_mode = "DISABLED"
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled_apis]
}

resource "google_artifact_registry_repository" "sport_slot_repo" {
  repository_id = var.artifact_repo_name
  project       = var.project_id
  location      = var.region
  format        = "DOCKER"
  description   = "SportSlot container images"
  mode          = "STANDARD_REPOSITORY"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled_apis]
}

# Downstream env CI (WIF principalSet) reads images for same-SHA promote
# (docs/design/same-sha-image-promote.md). Empty list = no external readers.
resource "google_artifact_registry_repository_iam_member" "external_readers" {
  for_each = toset(var.artifact_registry_reader_members)

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.sport_slot_repo.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

# Cloud Build source-staging bucket (`gcloud builds submit
# --gcs-source-staging-dir`, scripts/build_push.sh). Previously
# auto-created by Cloud Build on first use — absent from a fresh
# project until the first manual build, which left
# wif_iam.tf's ci_cloudbuild_staging_object_admin IAM binding 404ing
# against a bucket that didn't exist yet (DR drill Pass 1, finding #8).
resource "google_storage_bucket" "cloudbuild_staging" {
  name                        = "${var.project_id}-cloudbuild"
  project                     = var.project_id
  location                    = upper(var.region)
  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }

  depends_on = [google_project_service.enabled_apis]
}
