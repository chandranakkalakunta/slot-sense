# Load Balancer Backends — Phase 8b.2
#
# GCS bucket (frontend static assets) + backend bucket with SPA 404→200 catch-all;
# Cloud Run serverless NEG + backend service for the API. Both backends are
# consumed by the URL map in load_balancer_routing.tf.
#
# The GCS bucket is intentionally public-read (allUsers objectViewer) — it stores
# only pre-built frontend assets with no PII. uniform_bucket_level_access is
# required so the public IAM binding applies uniformly (per ADR-0031 Decision 2).
#
# SPA routing: Vite builds a single index.html. Client routes are rewritten to
# /index.html via path_rule url_rewrite in load_balancer_routing.tf (required —
# defaultCustomErrorResponsePolicy 404→index.html alone can return HTTP 200 with
# an empty body on backend buckets). Custom error remains best-effort for
# unlisted dynamic paths.

# ── GCS bucket (stores frontend/dist/ output uploaded in Phase 8b.2b CI step) ──

resource "google_storage_bucket" "frontend" {
  name                        = "${var.project_id}-frontend"
  project                     = var.project_id
  location                    = upper(var.region)
  uniform_bucket_level_access = true

  labels = var.default_labels
}

# Project-scoped exception to the org's domain-restricted-sharing
# policy, permitting allUsers on the public static-asset bucket.
# Reproduces the override sport-slot-dev has had since ADR-0031.
resource "google_org_policy_policy" "allow_public_members" {
  name   = "projects/${var.project_number}/policies/iam.allowedPolicyMemberDomains"
  parent = "projects/${var.project_number}"
  spec {
    rules {
      allow_all = "TRUE"
    }
  }
  depends_on = [google_project_service.enabled_apis]
}

# allUsers objectViewer — deliberate, public static web assets, no PII.
resource "google_storage_bucket_iam_member" "frontend_public_read" {
  bucket     = google_storage_bucket.frontend.name
  role       = "roles/storage.objectViewer"
  member     = "allUsers"
  depends_on = [google_org_policy_policy.allow_public_members]
}

# ── Frontend backend bucket (LB attachment, CDN enabled) ──

resource "google_compute_backend_bucket" "frontend" {
  name                 = "slotsense-frontend-bucket"
  project              = var.project_id
  bucket_name          = google_storage_bucket.frontend.name
  enable_cdn           = true
  edge_security_policy = google_compute_security_policy.frontend_edge.id

  # USE_ORIGIN_HEADERS: Cloud CDN respects Cache-Control values set as GCS
  # object metadata at upload time. Required so that no-cache files (index.html,
  # sw.js, etc.) are revalidated on every request rather than cached for
  # defaultTtl=3600s as CACHE_ALL_STATIC would impose.
  cdn_policy {
    cache_mode = "USE_ORIGIN_HEADERS"
  }
}

# ── Cloud Run serverless NEG + API backend service ──

# Serverless NEG is REGIONAL; the backend service referencing it is GLOBAL.
resource "google_compute_region_network_endpoint_group" "api_neg" {
  name                  = "slotsense-api-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.sport_slot_api.name
  }
}

resource "google_compute_backend_service" "api" {
  name                  = "slotsense-api-backend"
  project               = var.project_id
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  enable_cdn            = false
  security_policy       = google_compute_security_policy.api.id

  backend {
    group = google_compute_region_network_endpoint_group.api_neg.id
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}
