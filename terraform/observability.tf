# Observability & Alerting Baseline — ADR-0040 (PR-2)
#
# Everything below is a CREATE — no imports, no existing live
# resources to match. Terraform is the only way any of this comes
# into existence (ADR-0040 D13 / Alternatives #1: console-created
# alerts rejected as regressing ADR-0038's "apply is the rebuild
# path" the week after shipping it).
#
# Thresholds throughout are PROVISIONAL (measured-gates principle):
# set loose now, tightened once SLO-LOAD-TEST (PR-3 follow-on)
# produces real traffic distributions. See backlog ALERT-THRESHOLD-TUNE.

# ─── API enablement ───
#
# monitoring.googleapis.com is already enabled live (verified via
# `gcloud services list --enabled`, 2026-07-17) — not re-declared
# here, matching apis.tf's existing pattern of not managing
# already-enabled APIs it doesn't own. clouderrorreporting is the one
# gap the audit predicted.

resource "google_project_service" "clouderrorreporting" {
  project            = var.project_id
  service            = "clouderrorreporting.googleapis.com"
  disable_on_destroy = false
}

# ─── D9: Notification channels ───

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Admin Email"
  type         = "email"

  labels = {
    email_address = "admin@chandraailabs.com"
  }
}

# SMS is console-owned operator config, TF-referenced read-only —
# mirrors ADR-0038's secret shells-vs-values pattern (contact info as
# operator config, not a Terraform-managed value). The number never
# appears in the repo or in tfvars. Gated behind var.enable_sms_alerts
# (default false): an unconditional lookup FAILED THE ENTIRE PLAN on a
# brand-new environment with no console-created channel yet (DR drill
# Pass 1, GAP 2.3) — new environments now build email-only, with SMS
# added after the channel is created and phone-verified by hand. Set
# enable_sms_alerts = true in a given environment's tfvars only once
# that channel exists; the exact display name "Coordinator SMS" is the
# contract this data source depends on. Legacy sport-slot-dev already
# has the channel — its tfvars (gitignored) must set
# enable_sms_alerts = true or its alert policies silently drop SMS.
data "google_monitoring_notification_channel" "sms" {
  count        = var.enable_sms_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Coordinator SMS"
  type         = "sms"
}

locals {
  observability_channels = concat(
    [google_monitoring_notification_channel.email.id],
    var.enable_sms_alerts ? [data.google_monitoring_notification_channel.sms[0].name] : []
  )
}

# ─── D10: Uptime checks (two deliberately redundant paths) ───
#
# Edge path uses probe.slotsense.chandraailabs.com — a reserved,
# tenant-independent host (wildcard DNS + wildcard cert already cover
# it) rather than a real tenant subdomain like rvrg. Rationale: an
# unauthenticated /health probe never exercises tenant resolution
# anyway, so probing a real tenant host would buy nothing; tenant-
# routing verification is SMOKE-E2E's job, not an uptime check's.
# Still exercises DNS, cert, Cloud Armor, LB, and backend together.
# Service path isolates app health from edge health — one red / one
# green localizes the fault layer immediately. Route verified live
# 2026-07-17: GET /health returned 200 on both hosts
# (backend/src/sport_slot/health.py:14 — pure liveness, no dependency
# calls, per ADR-0006 Decision 4; deliberately not /readyz, which
# pings Firestore and would conflate app health with a Firestore blip).
# Sole uptime probe by design: Cloud Run ingress
# (internal-and-cloud-load-balancing, Phase 8b) rejects direct *.run.app
# probes. App-vs-edge localization: edge check + platform 5xx/latency alerts.

# Probe host is synthetic under the env base domain (ADR-0046): covered by
# the wildcard A + cert; not a real tenant. Each env probes its own zone.
resource "google_monitoring_uptime_check_config" "edge_health" {
  project      = var.project_id
  display_name = "Edge health — probe.${var.base_domain}"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/health"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "probe.${var.base_domain}"
    }
  }
}


# ─── Log-based metrics ───
#
# firestore_backup_failures: filter is DEFENSIVE, not yet validated
# against a real failure event — Firestore backup operations are new
# as of ADR-0038/PR-1a and no failure has occurred to observe the
# actual audit-log shape. Matches on the Firestore backup admin-activity
# audit log method name and a non-OK response status, which is the
# documented shape for Cloud Audit Logs on managed operations in this
# project generally. VALIDATE AT DRILL / FIRST REAL FAILURE — flagged
# per ADR-0040 D11 and the PR-2 report.
resource "google_logging_metric" "firestore_backup_failures" {
  project     = var.project_id
  name        = "firestore_backup_failures"
  description = "Failed Firestore backup schedule operations (ADR-0038/ADR-0040). Filter is defensive/provisional — validate at drill or first real failure."

  filter = <<-EOT
    resource.type="audited_resource"
    protoPayload.serviceName="firestore.googleapis.com"
    protoPayload.methodName:"Backup"
    severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# voice_turns / agent_text_turns: built on Cloud Run PLATFORM request
# logs (run.googleapis.com/requests), not application logs — one
# consistent source for both counters, zero app-code change, exact
# counts. Verified 2026-07-17 against a real /agent/query log entry
# (logName "projects/sport-slot-dev/logs/run.googleapis.com%2Frequests",
# resource.type "cloud_run_revision", httpRequest.requestUrl
# "https://rvrg.slotsense.chandraailabs.com/api/v1/agent/query",
# httpRequest.status 200) via `gcloud logging read`. 200-only is
# deliberate: a rejected request never reached STT/Gemini and isn't a
# costed turn. App-level structured logging does NOT give an
# unconditional per-turn event today (voice.py logs
# "voice_request_received" unconditionally, but agent.py's /query
# router and orchestrator.run_agent have no equivalent — every log
# call there is conditional on a specific branch) — see backlog
# AGENT-TURN-EVENT for the follow-up to add one.
resource "google_logging_metric" "voice_turns" {
  project     = var.project_id
  name        = "voice_turns"
  description = "Successful /agent/voice requests (Cloud Run platform request log), ADR-0040 D12. Counting only — no enforcement."

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="sport-slot-api"
    logName="projects/${var.project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl:"/agent/voice"
    httpRequest.status=200
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_logging_metric" "agent_text_turns" {
  project     = var.project_id
  name        = "agent_text_turns"
  description = "Successful /agent/query requests (Cloud Run platform request log), ADR-0040 D12. Counting only — no enforcement."

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="sport-slot-api"
    logName="projects/${var.project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl:"/agent/query"
    httpRequest.status=200
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# ─── D11: Alert policies (thresholds provisional — see file header) ───

resource "google_monitoring_alert_policy" "error_rate" {
  project               = var.project_id
  display_name          = "sport-slot-api — 5xx error rate > 5% (5 min)"
  combiner              = "OR"
  notification_channels = local.observability_channels

  conditions {
    display_name = "5xx ratio over 5%"

    condition_monitoring_query_language {
      duration = "300s"
      query    = <<-EOT
        fetch cloud_run_revision::run.googleapis.com/request_count
        | filter resource.service_name == 'sport-slot-api'
        | group_by 5m,
            [err_ratio: sum(if(metric.response_code_class == '5xx', val(), 0)) / sum(val())]
        | every 1m
        | condition val() > 0.05
      EOT 
      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "latency_p95" {
  project               = var.project_id
  display_name          = "sport-slot-api — p95 latency > 2500ms (15 min)"
  combiner              = "OR"
  notification_channels = local.observability_channels

  conditions {
    display_name = "p95 request latency over 2500ms"

    condition_threshold {
      filter = <<-EOT
        resource.type = "cloud_run_revision"
        AND resource.labels.service_name = "sport-slot-api"
        AND metric.type = "run.googleapis.com/request_latencies"
      EOT

      comparison      = "COMPARISON_GT"
      threshold_value = 2500
      duration        = "900s"

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MEAN"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "uptime_failure" {
  project               = var.project_id
  display_name          = "Uptime check failing (edge or service path)"
  combiner              = "OR"
  notification_channels = local.observability_channels

  conditions {
    display_name = "Edge uptime check failing from >=2 regions"

    condition_threshold {
      filter = <<-EOT
        resource.type = "uptime_url"
        AND metric.type = "monitoring.googleapis.com/uptime_check/check_passed"
        AND metric.labels.check_id = "${google_monitoring_uptime_check_config.edge_health.uptime_check_id}"
      EOT

      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "60s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 2 # standard 2+ region condition per ADR-0040 D11
      }
    }
  }
  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "firestore_backup_failure" {
  project               = var.project_id
  display_name          = "Firestore backup failure (per-event)"
  combiner              = "OR"
  notification_channels = local.observability_channels

  conditions {
    display_name = "Any Firestore backup failure log event"

    condition_matched_log {
      filter = <<-EOT
        resource.type="audited_resource"
        protoPayload.serviceName="firestore.googleapis.com"
        protoPayload.methodName:"Backup"
        severity>=ERROR
      EOT
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }
}
