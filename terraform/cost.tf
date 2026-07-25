# Cost Guardrails — Billing Budget & Thresholds — ADR-0042 (PR-4)
#
# Audit finding #5: no cost guardrail existed and billingbudgets.googleapis.com
# had never been enabled — the ADR-0005 ₹5K/mo dev ceiling was enforced by
# nothing but attention. D18: ONE Terraform-managed budget, alert-only.
# Alert-only is a decision, not an omission — automated actuators (billing
# disable, service caps) are rejected because billing-disable destroys the
# project's serving ability as collateral damage; the human is the actuator.
# Notifications reuse the existing ADR-0040 channels
# (local.observability_channels, terraform/observability.tf) — same pager
# for cost as for outages.

resource "google_project_service" "billingbudgets" {
  project            = var.project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

# Budget ceiling parameterized by var.environment (PR-J) — the original
# PR-4 resource hardcoded dev-scale values, which would have silently
# applied the ₹5K dev ceiling to a prod environment's first apply.
# Prod amounts below are placeholders only — see TODO on the map.
locals {
  budget_amounts_inr = {
    "dev"  = "5000"
    "test" = "5000"
    # TODO(prod): confirm ceiling with Coordinator before first prod apply.
    "prod-india" = "5000"
    "prod-uae"   = "5000"
  }
  budget_display_names = {
    "dev"        = "SlotSense dev ceiling (ADR-0005)"
    "test"       = "SlotSense test ceiling (ADR-0005)"
    "prod-india" = "SlotSense prod-india ceiling (ADR-0005)"
    "prod-uae"   = "SlotSense prod-uae ceiling (ADR-0005)"
  }
}

# billing_account_id / project_number: discovered and verified read-only
# (PR-4 Step 1), not guessed —
#   gcloud billing projects describe sport-slot-dev \
#     --format='value(billingAccountName,billingEnabled)'
#     → billingAccounts/014A8C-586310-DE4575, billingEnabled=True
#   gcloud billing accounts describe 014A8C-586310-DE4575 \
#     --format='yaml(displayName,currencyCode,open)'
#     → currencyCode=INR, open=true — confirms the amount unit below (D18)
# matches the pre-existing var.billing_account_id / var.project_number
# defaults in variables.tf / terraform.tfvars.example exactly.

resource "google_billing_budget" "slotsense_dev_ceiling" {
  billing_account = var.billing_account_id
  display_name    = local.budget_display_names[var.environment]

  budget_filter {
    projects = ["projects/${var.project_number}"]

    # calendar_period is HCL-optional but the provider's budget_filter
    # description states exactly one of calendar_period/custom_period
    # must be provided — set explicitly (MONTH matches the ADR's
    # ₹5K/month framing) rather than relying on an implicit API default,
    # per the PR-3 lesson on defaulted-but-omitted fields.
    calendar_period = "MONTH"

    # D19: credits offset spend (the true cash picture) — explicit per
    # the ADR's own decision, not left to the (matching) API default.
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "INR"
      units         = local.budget_amounts_inr[var.environment]
    }
  }

  # D18: five graduated thresholds — 50/80/100/120% actual + 100% forecasted.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.2
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  # Billing Budgets API accepts Monitoring *email* channels only — SMS
  # (and other non-email types) return 400 INVALID_ARGUMENT. Verified live
  # 2026-07-21: email channel PATCH succeeds; email+SMS fails. Ops SMS
  # still covers uptime/error/latency policies via observability.tf.
  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.email.id,
    ]
    # Only the Admin Email channel — not billing-account IAM default
    # recipients. Flip to false if you want those as backup.
    disable_default_iam_recipients = true
  }

  depends_on = [google_project_service.billingbudgets]
}
