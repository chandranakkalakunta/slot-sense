variable "project_id" {
  description = "GCP project ID (e.g., sport-slot-dev)"
  type        = string

  validation {
    condition     = can(regex("^(sport-slot-dev|slot-sense-(dev|test|prod-[a-z]+)(-[0-9]+)?)$", var.project_id))
    error_message = "project_id must be sport-slot-dev (legacy) or slot-sense-{dev|test|prod-XX} with optional -NN suffix. Legacy name accepted during migration (remove after — NAMING-MIGRATION)."
  }
}

variable "project_number" {
  description = "GCP project number (auto-assigned by Google)"
  type        = string
}

variable "organization_id" {
  description = "GCP organization ID (chandraailabs.com)"
  type        = string
  default     = "833112493322"
}

variable "billing_account_id" {
  # Default verified read-only, ADR-0042/PR-4 Step 1:
  #   gcloud billing projects describe sport-slot-dev \
  #     --format='value(billingAccountName,billingEnabled)'
  # Not a secret — it IS config (used by terraform/cost.tf's
  # google_billing_budget, which is billing-account-scoped).
  description = "GCP billing account ID"
  type        = string
  default     = "014A8C-586310-DE4575"
  sensitive   = false
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "asia-south1"

  validation {
    condition     = contains(["asia-south1", "asia-southeast1", "europe-west1", "us-central1"], var.region)
    error_message = "region must be one of the approved regions."
  }
}

variable "zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "asia-south1-a"
}

variable "environment" {
  description = "Environment name (dev, test, prod-india, etc.)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod-india", "prod-uae"], var.environment)
    error_message = "environment must be: dev | test | prod-india | prod-uae"
  }
}

variable "github_repository" {
  # NOTE: terraform.tfvars (gitignored) overrides this default. If you
  # change this value, also check/update terraform.tfvars — the default
  # here is NOT necessarily what's actually applied. (Learned the hard
  # way during the repo rename — see CHANGELOG.)
  description = "GitHub repo for Workload Identity Federation"
  type        = string
  default     = "chandranakkalakunta/slot-sense"
}

variable "default_labels" {
  description = "Labels applied to all resources for cost tracking and management"
  type        = map(string)
  default = {
    project    = "slot-sense"
    managed_by = "terraform"
    owner      = "chandra-ai-labs"
  }
}

variable "base_domain" {
  description = "Per-env base domain (ADR-0046). Tenants = {slug}.{base_domain}; one wildcard DNS A per env. Examples: slotsense-dev.chandraailabs.com, slotsense-test.chandraailabs.com, slotsense.chandraailabs.com (prod)."
  type        = string
  default     = "slotsense.chandraailabs.com"
}

variable "admin_host" {
  description = "Platform admin host (typically admin.<base_domain>)"
  type        = string
  default     = "admin.slotsense.chandraailabs.com"
}

variable "artifact_repo_name" {
  description = "Artifact Registry repo name. Legacy dev: sport-slot-repo; new slot-sense-* envs: slot-sense-repo."
  type        = string
  default     = "sport-slot-repo"
}

variable "bootstrap_image_tag" {
  description = "Image tag Cloud Run points at on first create. CI owns the live image after (ignore_changes)."
  type        = string
  default     = "faa1695"
}

variable "enable_sms_alerts" {
  description = "Whether to attach the console-created 'Coordinator SMS' notification channel to alert policies. New environments start email-only (the channel requires manual phone verification); set true after creating and verifying the channel. Legacy sport-slot-dev sets true."
  type        = bool
  default     = false
}
