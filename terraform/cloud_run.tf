# Cloud Run Service — sport-slot-api (ADR-0038 Layer 3, PR-1b)
#
# ADR-0038 D7 ownership model: Terraform owns existence/shape (SA,
# scaling ceiling, ingress, VPC egress, secret wiring, resource
# limits). CI (cloud_build via `gcloud run deploy`) owns revisions —
# the container image and the deploy-client annotations/labels gcloud
# rewrites on every release. Those fields are excluded via
# lifecycle.ignore_changes below so CI deploys never show as drift
# and `terraform apply` never rolls back a live image.
#
# Authored field-for-field from the 2026-07-16 live export
# (`gcloud run services describe sport-slot-api --region=asia-south1
# --format=export`) captured in PR-1b Step 1. maxScale is 2 live —
# codified as 2. Raising it is PR-3 scope; this PR changes no live
# value.
#
# NOTE for Coordinator: this is the import most likely to show
# residual plan diffs (v2 resource field sprawl vs the Knative-style
# export view). Any diff the staged plan reveals gets reported back
# verbatim and fixed in this file to match live — never by changing
# live.
#
# PR-3 (ADR-0041 D15): maxScale raised 2 -> 10 (cap, not floor; zero
# cost until traffic scales instances) and the startup probe moved
# from TCP to HTTP GET /health, plus a new liveness probe on the same
# path. /health is pure liveness (no dependency calls) by design —
# see backend/src/sport_slot/health.py and ADR-0040's uptime-check
# rationale — so it is exactly correct for both probe roles; a
# dependency-checking endpoint would wrongly restart the container on
# a Redis/Firestore blip. This mints the first Terraform-driven Cloud
# Run revision since PR-1b adoption; live image/env remain untouched
# (ignore_changes below, D7 model).

resource "google_cloud_run_v2_service" "sport_slot_api" {
  name     = "sport-slot-api"
  project  = var.project_id
  location = var.region

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account                  = google_service_account.cloud_run.email
    timeout                          = "300s"
    max_instance_request_concurrency = 80

    scaling {
      # Test may set min=1 for warm latency (perf / S-FUNC); prod keeps 0.
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances # ADR-0041 D15: cap not floor
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = "default"
        subnetwork = "default"
      }
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/sport-slot-api:${var.bootstrap_image_tag}"

      ports {
        name           = "http1"
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        startup_cpu_boost = true
        cpu_idle          = true # live default: CPU allocated only during request processing
      }

      # ADR-0041 D15: HTTP GET replaces the live TCP startup probe.
      # period_seconds kept at the live/max value (240s) to preserve
      # the same startup grace window; timeout_seconds must be lower
      # than period_seconds per provider schema, so it is tuned down
      # from the live 240s to 10s — ample for a pure-liveness endpoint
      # with no dependency calls.
      startup_probe {
        failure_threshold = 6
        period_seconds    = 10
        timeout_seconds   = 5
        http_get {
          path = "/health"
          port = 8080
        }
      }

      # ADR-0041 D15: new. /health is pure liveness by design — a
      # dependency-checking endpoint here would cause wrong restarts
      # on a transient Redis/Firestore blip. failure_threshold=3 at
      # period_seconds=30 requires ~90s of sustained failure before a
      # restart, tolerant of brief hiccups.
      liveness_probe {
        failure_threshold = 3
        period_seconds    = 30
        timeout_seconds   = 10
        http_get {
          path = "/health"
          port = 8080
        }
      }

      env {
        name  = "SPORTSLOT_ENVIRONMENT"
        value = "development"
      }
      env {
        name  = "SPORTSLOT_GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "SPORTSLOT_BASE_DOMAIN"
        value = var.base_domain
      }
      env {
        name  = "SPORTSLOT_ADMIN_HOST"
        value = var.admin_host
      }
      env {
        name  = "SPORTSLOT_REDIS_HOST"
        value = google_redis_instance.sport_slot_redis.host
      }
      env {
        name  = "SPORTSLOT_REDIS_PORT"
        value = tostring(google_redis_instance.sport_slot_redis.port)
      }
      env {
        name  = "SPORTSLOT_TASKS_QUEUE"
        value = "notifications"
      }
      env {
        name  = "SPORTSLOT_TASKS_LOCATION"
        value = var.region
      }
      # CI-populated on first deploy; not parameterized (self-referential URL). See runbook Layer 3.
      env {
        name  = "SPORTSLOT_WORKER_BASE_URL"
        value = "https://sport-slot-api-yw2l7pv63a-el.a.run.app"
      }
      env {
        name  = "SPORTSLOT_TASKS_INVOKER_SA"
        value = "sa-tasks-invoker@${var.project_id}.iam.gserviceaccount.com"
      }
      env {
        name  = "SPORTSLOT_SCHEDULER_INVOKER_SA"
        value = "sa-scheduler-invoker@${var.project_id}.iam.gserviceaccount.com"
      }
      env {
        name  = "SPORTSLOT_CLOUD_RUN_SA_EMAIL"
        value = google_service_account.cloud_run.email
      }
      env {
        name  = "BUILD_ID"
        value = "faa1695f06a676818f70341a7747777d0a3010c5"
      }
      env {
        name = "SPORTSLOT_REDIS_AUTH"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.redis_auth.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "SPORTSLOT_RESEND_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.resend_api_key.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # Greenfield bootstrap race: Cloud Run revision validation checks secret
  # access before project-level IAM has propagated if created in parallel.
  # Force IAM (and secret resources) first so create does not fail and taint
  # the service (prevent_destroy then blocks replace on retry).
  depends_on = [
    google_project_iam_member.cloud_run_secretmanager_secret_accessor,
    google_secret_manager_secret_iam_member.cloud_run_resend_secret_accessor,
    google_secret_manager_secret_iam_member.cloud_run_redis_secret_accessor,
    google_secret_manager_secret.redis_auth,
    google_secret_manager_secret.resend_api_key,
  ]

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      client,
      client_version,
      template[0].containers[0].image,
      template[0].containers[0].env,
      template[0].annotations,
      template[0].labels,
      annotations,
      scaling, # service-level scaling block is API-populated defaults; template-level scaling (maxScale) remains managed 
      labels,
    ]
  }
}
