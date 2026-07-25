#!/usr/bin/env bash
#
# drill-bootstrap.sh — single-command environment build (PR-G)
#
# Encodes the DR drill Pass 1 rebuild sequence (docs/runbooks/disaster-recovery.md
# §4.1) into one script so a new SlotSense GCP environment can be built end to
# end. Every ordering constraint below was learned the hard way during the
# drill — do not reorder phases without re-reading that runbook.
#
# Usage:
#   scripts/drill-bootstrap.sh [options]
#   scripts/drill-bootstrap.sh --help
#
# Coordinator-run only. Resend API key is NEVER passed as a flag — either
# typed at a masked prompt, or (in --non-interactive mode) supplied via the
# SLOTSENSE_RESEND_API_KEY environment variable.
#
# Resumable: on failure, re-run with --project-id <id> --start-phase <N> to
# continue. Per-project state (region/zone/env/tfvars path/image tag/etc.)
# is cached in a gitignored state file so resume doesn't require re-passing
# every flag.

set -euo pipefail

# ─── Paths ──────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# ─── Defaults (Phase 0) ─────────────────────────────────────────────────
DEFAULT_REGION="asia-south1"
DEFAULT_ZONE="asia-south1-c" # NOTE: decorative for Redis — see report; base_infra.tf
                              # hardcodes location_id="asia-south1-c" independent of this var.
DEFAULT_BASE_DOMAIN="slotsense.chandraailabs.com"
DEFAULT_ADMIN_HOST="admin.slotsense.chandraailabs.com"
DEFAULT_ARTIFACT_REPO="slot-sense-repo"
DEFAULT_ORG_ID="833112493322"
DEFAULT_BILLING_ACCOUNT="014A8C-586310-DE4575"
GITHUB_REPOSITORY="chandranakkalakunta/slot-sense"

# project_id validation regex — MUST stay in sync with terraform/variables.tf's
# `variable "project_id"` validation block. Checked here so a bad project_id
# fails in <1s, not after project creation has already started.
PROJECT_ID_REGEX='^(sport-slot-dev|slot-sense-(dev|test|prod-[a-z]+)(-[0-9]+)?)$'
VALID_REGIONS="asia-south1 asia-southeast1 europe-west1 us-central1"
VALID_ENVIRONMENTS="dev test prod-india prod-uae"

# ─── CLI-settable inputs (blank = prompt in interactive mode) ──────────
PROJECT_ID=""
REGION="$DEFAULT_REGION"
ZONE="$DEFAULT_ZONE"
ENVIRONMENT=""
BASE_DOMAIN="$DEFAULT_BASE_DOMAIN"
ADMIN_HOST="$DEFAULT_ADMIN_HOST"
ARTIFACT_REPO_NAME="$DEFAULT_ARTIFACT_REPO"
ORG_ID=""
BILLING_ACCOUNT=""
RESEND_API_KEY=""

NON_INTERACTIVE=0
AUTO_YES=0
DRY_RUN=0
START_PHASE=0

# ─── Runtime state (populated during phases, cached to STATE_FILE) ─────
PROJECT_NUMBER=""
STATE_BUCKET=""
TFVARS_PATH=""
TFVARS_NAME=""
IMAGE_TAG=""
DEPLOY_START_TS=""

# Filled in once PROJECT_ID is known.
STATE_FILE=""
OUTPUT_FILE=""
CMDLOG_FILE=""
TIMING_FILE=""

# ─── Output helpers ──────────────────────────────────────────────────────
timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
  local line
  line="[$(timestamp)] $*"
  echo "${line}"
  if [[ -n "${CMDLOG_FILE}" ]]; then
    echo "${line}" >> "${CMDLOG_FILE}"
  fi
}

banner() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $*"
  echo "═══════════════════════════════════════════════════════════════"
}

fail() {
  local phase="$1"; shift
  log "FATAL (Phase ${phase}): $*"
  echo "" >&2
  echo "STOPPED at Phase ${phase}." >&2
  echo "Resume with:" >&2
  echo "  scripts/drill-bootstrap.sh --project-id ${PROJECT_ID:-<project-id>} --start-phase ${phase} $( [[ ${AUTO_YES} -eq 1 ]] && echo '--yes' )" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required binary '$1' not found on PATH." >&2
    exit 1
  }
}

# ─── State file (per project_id, gitignored) ────────────────────────────
state_path_for() { echo "${REPO_ROOT}/.drill-bootstrap-state-$1.env"; }

state_load() {
  [[ -f "${STATE_FILE}" ]] || return 0
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

state_set() {
  local key="$1" value="$2"
  [[ -n "${STATE_FILE}" ]] || return 0
  touch "${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
  if grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -F'=' -v k="${key}" -v v="${key}=${value}" \
      '{ if ($1==k) print v; else print $0 }' "${STATE_FILE}" > "${tmp}"
    mv "${tmp}" "${STATE_FILE}"
  else
    echo "${key}=${value}" >> "${STATE_FILE}"
  fi
}

record_elapsed() {
  local phase="$1" label="$2" seconds="$3"
  [[ -n "${TIMING_FILE}" ]] || return 0
  echo "Phase ${phase} (${label})|${seconds}s" >> "${TIMING_FILE}"
}

# ─── Usage ────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
drill-bootstrap.sh — single-command SlotSense environment build (PR-G)

Usage:
  scripts/drill-bootstrap.sh [options]

Options:
  --project-id ID            GCP project id (required; see naming rule below)
  --region REGION            asia-south1 | asia-southeast1 | europe-west1 | us-central1
                              (default: asia-south1)
  --zone ZONE                Zonal default for the provider block (default: asia-south1-c)
  --environment ENV          dev | test | prod-india | prod-uae
  --base-domain DOMAIN       (default: slotsense.chandraailabs.com)
  --admin-host HOST          (default: admin.slotsense.chandraailabs.com)
  --artifact-repo-name NAME  (default: slot-sense-repo)
  --org-id ID                GCP organization id (looked up + confirmed if omitted)
  --billing-account ID       GCP billing account id (looked up + confirmed if omitted)
  --non-interactive          Do not prompt; all required values must come from
                              flags/env. Resend key MUST be in SLOTSENSE_RESEND_API_KEY.
  --yes                      Auto-approve terraform applies and confirmation
                              prompts in sub-scripts (still fails fast on errors).
  --start-phase N            Resume from phase N (0-9). Reloads cached state
                              for --project-id from a previous run.
  --dry-run                  Validate inputs and print the plan; makes NO
                              gcloud/terraform/firebase/network calls.
  -h, --help                 Show this help and exit.

project_id naming rule (must match terraform/variables.tf):
  sport-slot-dev (legacy) OR slot-sense-{dev|test|prod-XX}[-NN]

Examples:
  scripts/drill-bootstrap.sh --project-id slot-sense-test-01 --environment test
  scripts/drill-bootstrap.sh --project-id slot-sense-dev-02 --environment dev --dry-run
  scripts/drill-bootstrap.sh --project-id slot-sense-test-01 --start-phase 6 --yes

Resend API key: interactive mode prompts (input hidden); --non-interactive
mode requires SLOTSENSE_RESEND_API_KEY to be exported in the environment.
It is never accepted as a command-line flag and never echoed.
EOF
}

# ─── Local validation (no network calls) ────────────────────────────────
validate_project_id() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "ERROR: project_id is required." >&2
    return 1
  fi
  if [[ ! "$id" =~ $PROJECT_ID_REGEX ]]; then
    echo "ERROR: project_id '$id' does not match terraform/variables.tf's validation:" >&2
    echo "  sport-slot-dev (legacy) or slot-sense-{dev|test|prod-XX}[-NN]" >&2
    return 1
  fi
  return 0
}

validate_region() {
  local r="$1" ok=0
  for v in ${VALID_REGIONS}; do [[ "$r" == "$v" ]] && ok=1; done
  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: region '$r' must be one of: ${VALID_REGIONS}" >&2
    return 1
  fi
  return 0
}

validate_environment() {
  local e="$1" ok=0
  for v in ${VALID_ENVIRONMENTS}; do [[ "$e" == "$v" ]] && ok=1; done
  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: environment '$e' must be one of: ${VALID_ENVIRONMENTS}" >&2
    return 1
  fi
  return 0
}

# ─── Arg parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --base-domain) BASE_DOMAIN="$2"; shift 2 ;;
    --admin-host) ADMIN_HOST="$2"; shift 2 ;;
    --artifact-repo-name) ARTIFACT_REPO_NAME="$2"; shift 2 ;;
    --org-id) ORG_ID="$2"; shift 2 ;;
    --billing-account) BILLING_ACCOUNT="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --yes) AUTO_YES=1; shift ;;
    --start-phase) START_PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "${START_PHASE}" =~ ^[0-9]$ ]]; then
  echo "ERROR: --start-phase must be an integer 0-9." >&2
  exit 1
fi

# ─── PHASE 0 — Inputs ────────────────────────────────────────────────────
phase0() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 0 — Inputs"

  if [[ -z "${PROJECT_ID}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail 0 "--non-interactive requires --project-id."
    fi
    read -r -p "project_id: " PROJECT_ID
  fi
  validate_project_id "${PROJECT_ID}" || fail 0 "invalid project_id."

  STATE_FILE="$(state_path_for "${PROJECT_ID}")"
  OUTPUT_FILE="${REPO_ROOT}/bootstrap-output-${PROJECT_ID}-$(date -u '+%Y%m%dT%H%M%SZ').md"
  CMDLOG_FILE="${REPO_ROOT}/.drill-bootstrap-${PROJECT_ID}.cmdlog"
  TIMING_FILE="${REPO_ROOT}/.drill-bootstrap-${PROJECT_ID}.timing"
  state_load

  # Flags override cached state; cached state fills in anything left blank
  # (this is what makes --start-phase N usable without repeating every flag).
  REGION="${REGION:-${CACHED_REGION:-$DEFAULT_REGION}}"
  [[ -n "${CACHED_REGION:-}" && "${REGION}" == "${DEFAULT_REGION}" ]] && REGION="${CACHED_REGION}"
  if [[ -z "${ENVIRONMENT}" && -n "${CACHED_ENVIRONMENT:-}" ]]; then
    ENVIRONMENT="${CACHED_ENVIRONMENT}"
  fi
  if [[ "${ZONE}" == "${DEFAULT_ZONE}" && -n "${CACHED_ZONE:-}" ]]; then
    ZONE="${CACHED_ZONE}"
  fi
  if [[ "${BASE_DOMAIN}" == "${DEFAULT_BASE_DOMAIN}" && -n "${CACHED_BASE_DOMAIN:-}" ]]; then
    BASE_DOMAIN="${CACHED_BASE_DOMAIN}"
  fi
  if [[ "${ADMIN_HOST}" == "${DEFAULT_ADMIN_HOST}" && -n "${CACHED_ADMIN_HOST:-}" ]]; then
    ADMIN_HOST="${CACHED_ADMIN_HOST}"
  fi
  if [[ "${ARTIFACT_REPO_NAME}" == "${DEFAULT_ARTIFACT_REPO}" && -n "${CACHED_ARTIFACT_REPO_NAME:-}" ]]; then
    ARTIFACT_REPO_NAME="${CACHED_ARTIFACT_REPO_NAME}"
  fi
  [[ -n "${ORG_ID}" ]] || ORG_ID="${CACHED_ORG_ID:-}"
  [[ -n "${BILLING_ACCOUNT}" ]] || BILLING_ACCOUNT="${CACHED_BILLING_ACCOUNT:-}"
  PROJECT_NUMBER="${CACHED_PROJECT_NUMBER:-}"
  STATE_BUCKET="${CACHED_STATE_BUCKET:-${PROJECT_ID}-tfstate}"
  TFVARS_NAME="${CACHED_TFVARS_NAME:-${PROJECT_ID}.tfvars}"
  TFVARS_PATH="${TF_DIR}/${TFVARS_NAME}"
  IMAGE_TAG="${CACHED_IMAGE_TAG:-}"

  validate_region "${REGION}" || fail 0 "invalid region."

  if [[ -z "${ENVIRONMENT}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail 0 "--non-interactive requires --environment."
    fi
    read -r -p "environment (dev|test|prod-india|prod-uae): " ENVIRONMENT
  fi
  validate_environment "${ENVIRONMENT}" || fail 0 "invalid environment."

  if [[ -z "${ORG_ID}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      ORG_ID="${DEFAULT_ORG_ID}"
    elif [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      ORG_ID="${DEFAULT_ORG_ID}"
    else
      local looked_up
      looked_up="$(gcloud organizations list --format='value(ID)' 2>/dev/null | head -n1 || true)"
      looked_up="${looked_up:-$DEFAULT_ORG_ID}"
      read -r -p "organization_id [${looked_up}]: " ORG_ID
      ORG_ID="${ORG_ID:-$looked_up}"
    fi
  fi

  if [[ -z "${BILLING_ACCOUNT}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      BILLING_ACCOUNT="${DEFAULT_BILLING_ACCOUNT}"
    elif [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      BILLING_ACCOUNT="${DEFAULT_BILLING_ACCOUNT}"
    else
      local looked_up
      looked_up="$(gcloud billing accounts list --filter='open=true' --format='value(ACCOUNT_ID)' 2>/dev/null | head -n1 || true)"
      looked_up="${looked_up:-$DEFAULT_BILLING_ACCOUNT}"
      read -r -p "billing_account_id [${looked_up}]: " BILLING_ACCOUNT
      BILLING_ACCOUNT="${BILLING_ACCOUNT:-$looked_up}"
    fi
  fi

  if [[ "${START_PHASE}" -le 5 ]]; then
    if [[ -n "${SLOTSENSE_RESEND_API_KEY:-}" ]]; then
      RESEND_API_KEY="${SLOTSENSE_RESEND_API_KEY}"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
      RESEND_API_KEY="dry-run-placeholder"
    elif [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail 0 "--non-interactive requires SLOTSENSE_RESEND_API_KEY to be exported."
    else
      read -r -s -p "resend_api_key (hidden, not echoed): " RESEND_API_KEY
      echo ""
      [[ -n "${RESEND_API_KEY}" ]] || fail 0 "resend_api_key must not be empty."
    fi
  fi

  echo ""
  echo "── Summary ──────────────────────────────────────────────"
  printf '  %-20s %s\n' "project_id:" "${PROJECT_ID}"
  printf '  %-20s %s\n' "region:" "${REGION}"
  printf '  %-20s %s\n' "zone:" "${ZONE}"
  printf '  %-20s %s\n' "environment:" "${ENVIRONMENT}"
  printf '  %-20s %s\n' "base_domain:" "${BASE_DOMAIN}"
  printf '  %-20s %s\n' "admin_host:" "${ADMIN_HOST}"
  printf '  %-20s %s\n' "artifact_repo_name:" "${ARTIFACT_REPO_NAME}"
  printf '  %-20s %s\n' "org_id:" "${ORG_ID}"
  printf '  %-20s %s\n' "billing_account_id:" "${BILLING_ACCOUNT}"
  printf '  %-20s %s\n' "resend_api_key:" "$( [[ -n "${RESEND_API_KEY}" ]] && echo '<set, hidden>' || echo '<not needed at this start-phase>' )"
  printf '  %-20s %s\n' "start_phase:" "${START_PHASE}"
  printf '  %-20s %s\n' "dry_run:" "${DRY_RUN}"
  echo "────────────────────────────────────────────────────────"

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      log "Non-interactive: proceeding without confirmation prompt."
    else
      local confirm
      read -r -p "Type BUILD to proceed with the above: " confirm
      [[ "${confirm}" == "BUILD" ]] || { echo "Aborted."; exit 1; }
    fi
  fi

  state_set CACHED_REGION "${REGION}"
  state_set CACHED_ZONE "${ZONE}"
  state_set CACHED_ENVIRONMENT "${ENVIRONMENT}"
  state_set CACHED_BASE_DOMAIN "${BASE_DOMAIN}"
  state_set CACHED_ADMIN_HOST "${ADMIN_HOST}"
  state_set CACHED_ARTIFACT_REPO_NAME "${ARTIFACT_REPO_NAME}"
  state_set CACHED_ORG_ID "${ORG_ID}"
  state_set CACHED_BILLING_ACCOUNT "${BILLING_ACCOUNT}"
  state_set CACHED_STATE_BUCKET "${STATE_BUCKET}"
  state_set CACHED_TFVARS_NAME "${TFVARS_NAME}"

  t1=$(date +%s); record_elapsed 0 "Inputs" "$((t1 - t0))"
}

# ─── PHASE 1 — Project foundation ───────────────────────────────────────
phase1() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 1 — Project foundation"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would create/verify project ${PROJECT_ID}, link billing, enable 3 bootstrap APIs,"
    log "[dry-run] create gs://${STATE_BUCKET}, write ${TFVARS_PATH}, run terraform init."
    t1=$(date +%s); record_elapsed 1 "Project foundation" "$((t1 - t0))"
    return 0
  fi

  if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
    log "Project ${PROJECT_ID} already exists — skipping create."
  else
    log "Running: gcloud projects create ${PROJECT_ID} --organization=${ORG_ID}"
    gcloud projects create "${PROJECT_ID}" --organization="${ORG_ID}" --name="${PROJECT_ID}" \
      || fail 1 "gcloud projects create failed."
  fi

  local attempt=1 max_attempts=5
  until gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)' 2>/dev/null | grep -q True; do
    log "Linking billing (attempt ${attempt}/${max_attempts})..."
    if gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"; then
      break
    fi
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      fail 1 "billing link failed after ${max_attempts} attempts (transient quota 403s were observed during the drill — check billing account permissions)."
    fi
    attempt=$((attempt + 1))
    sleep 15
  done
  log "Billing linked."

  gcloud config set project "${PROJECT_ID}" >/dev/null || fail 1 "gcloud config set project failed."
  gcloud auth application-default set-quota-project "${PROJECT_ID}" >/dev/null 2>&1 \
    || log "WARNING: could not set ADC quota project (non-fatal — continuing)."

  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  [[ -n "${PROJECT_NUMBER}" ]] || fail 1 "could not resolve project_number."
  log "project_number = ${PROJECT_NUMBER}"
  state_set CACHED_PROJECT_NUMBER "${PROJECT_NUMBER}"

  log "Enabling 3 bootstrap APIs (cloudresourcemanager, serviceusage, iam)..."
  gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com \
    --project="${PROJECT_ID}" || fail 1 "bootstrap API enablement failed."

  if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
    log "State bucket gs://${STATE_BUCKET} already exists — skipping create."
  else
    log "Creating state bucket gs://${STATE_BUCKET} (location ${REGION})..."
    gcloud storage buckets create "gs://${STATE_BUCKET}" \
      --location="${REGION}" --uniform-bucket-level-access \
      --project="${PROJECT_ID}" || fail 1 "state bucket create failed."
    gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning \
      || fail 1 "enabling versioning on state bucket failed."
  fi

  log "Writing ${TFVARS_PATH}"
  cat > "${TFVARS_PATH}" <<EOF
# Generated by scripts/drill-bootstrap.sh on $(timestamp) — gitignored (terraform/*.tfvars).
project_id          = "${PROJECT_ID}"
project_number      = "${PROJECT_NUMBER}"
organization_id     = "${ORG_ID}"
billing_account_id  = "${BILLING_ACCOUNT}"
region              = "${REGION}"
zone                = "${ZONE}"
environment         = "${ENVIRONMENT}"
github_repository   = "${GITHUB_REPOSITORY}"
base_domain         = "${BASE_DOMAIN}"
admin_host          = "${ADMIN_HOST}"
artifact_repo_name  = "${ARTIFACT_REPO_NAME}"
bootstrap_image_tag = "bootstrap-pending"
enable_sms_alerts   = false
EOF
  chmod 600 "${TFVARS_PATH}"

  log "Running: terraform init -reconfigure -backend-config=bucket=${STATE_BUCKET}"
  (cd "${TF_DIR}" && terraform init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="prefix=terraform/state") \
    || fail 1 "terraform init failed."

  t1=$(date +%s); record_elapsed 1 "Project foundation" "$((t1 - t0))"
}

# ─── PHASE 2 — Firebase ──────────────────────────────────────────────────
phase2() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 2 — Firebase"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would run: firebase projects:addfirebase ${PROJECT_ID}"
    t1=$(date +%s); record_elapsed 2 "Firebase" "$((t1 - t0))"
    return 0
  fi

  log "Running: firebase projects:addfirebase ${PROJECT_ID}"
  if ! firebase projects:addfirebase "${PROJECT_ID}" 2>&1 | tee -a "${CMDLOG_FILE}" | grep -qiE "already|success|Firebase resources"; then
    log "WARNING: addfirebase output was not clearly a success/already-added — check ${CMDLOG_FILE}. Continuing (idempotent by design)."
  fi

  log "NOTE: Email/Password sign-in provider is Terraform-managed (google_identity_platform_config.auth, PR-F)."
  log "      No manual console step is needed — it is created by the Phase 6 main apply."
  log "NOTE: SMS notification channel is SKIPPED by design (email-only new environment)."
  log "      To add later: Console -> Monitoring -> Alerting -> Notification Channels -> Add SMS,"
  log "      display name 'Coordinator SMS', complete phone verification, then set"
  log "      enable_sms_alerts = true in ${TFVARS_NAME} before the next apply."

  t1=$(date +%s); record_elapsed 2 "Firebase" "$((t1 - t0))"
}

# ─── PHASE 3 — Bootstrap-group apply ────────────────────────────────────
phase3() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 3 — Bootstrap-group apply (includes Redis — this will take ~10 minutes)"

  local targets=(
    "-target=google_project_service.enabled_apis"
    "-target=google_artifact_registry_repository.sport_slot_repo"
    "-target=google_project_iam_member.compute_sa_cloudbuild_builder"
    "-target=google_storage_bucket.cloudbuild_staging"
    "-target=google_redis_instance.sport_slot_redis"
    "-target=google_secret_manager_secret.redis_auth"
    "-target=google_secret_manager_secret.resend_api_key"
  )

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would run: terraform apply -var-file=${TFVARS_NAME} -auto-approve ${targets[*]}"
    t1=$(date +%s); record_elapsed 3 "Bootstrap-group apply" "$((t1 - t0))"
    return 0
  fi

  log "This will take a while (Redis instance creation is ~9-10 minutes). Please wait..."
  (cd "${TF_DIR}" && terraform apply -var-file="${TFVARS_NAME}" -auto-approve "${targets[@]}") \
    || fail 3 "bootstrap-group apply failed."

  t1=$(date +%s); record_elapsed 3 "Bootstrap-group apply" "$((t1 - t0))"
}

# ─── PHASE 4 — Image build ───────────────────────────────────────────────
phase4() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 4 — Image build"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would run: SLOTSENSE_PROJECT=${PROJECT_ID} SLOTSENSE_ARTIFACT_REPO=${ARTIFACT_REPO_NAME} SLOTSENSE_REGION=${REGION} scripts/build_push.sh"
    log "[dry-run] NOTE: build_push.sh takes NO tag argument — it always tags with the current git short SHA"
    log "[dry-run] and refuses to run on a dirty working tree. Adapted accordingly (verified in Step 2)."
    IMAGE_TAG="dry-run-tag"
    t1=$(date +%s); record_elapsed 4 "Image build" "$((t1 - t0))"
    return 0
  fi

  log "Running: SLOTSENSE_PROJECT=${PROJECT_ID} SLOTSENSE_ARTIFACT_REPO=${ARTIFACT_REPO_NAME} SLOTSENSE_REGION=${REGION} scripts/build_push.sh"
  SLOTSENSE_PROJECT="${PROJECT_ID}" SLOTSENSE_ARTIFACT_REPO="${ARTIFACT_REPO_NAME}" SLOTSENSE_REGION="${REGION}" \
    "${REPO_ROOT}/scripts/build_push.sh" || fail 4 "build_push.sh failed."

  [[ -f "${REPO_ROOT}/.last_image_tag" ]] || fail 4 "build_push.sh reported success but .last_image_tag is missing."
  IMAGE_TAG="$(cat "${REPO_ROOT}/.last_image_tag")"
  [[ -n "${IMAGE_TAG}" ]] || fail 4 "image tag read from .last_image_tag is empty."
  log "Built image tag: ${IMAGE_TAG}"

  log "Updating ${TFVARS_NAME}: bootstrap_image_tag = ${IMAGE_TAG}"
  local tmp
  tmp="$(mktemp)"
  sed "s/^bootstrap_image_tag = .*/bootstrap_image_tag = \"${IMAGE_TAG}\"/" "${TFVARS_PATH}" > "${tmp}"
  mv "${tmp}" "${TFVARS_PATH}"
  chmod 600 "${TFVARS_PATH}"

  state_set CACHED_IMAGE_TAG "${IMAGE_TAG}"
  t1=$(date +%s); record_elapsed 4 "Image build" "$((t1 - t0))"
}

# ─── PHASE 5 — Secret values (before main apply) ────────────────────────
phase5() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 5 — Secret values"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would populate redis-auth (from 'gcloud redis instances get-auth-string') and resend-api-key (from Phase 0 prompt) secret versions."
    t1=$(date +%s); record_elapsed 5 "Secret values" "$((t1 - t0))"
    return 0
  fi

  log "Fetching Redis AUTH string and adding as redis-auth secret version..."
  gcloud redis instances get-auth-string sport-slot-redis --region="${REGION}" --project="${PROJECT_ID}" \
    | gcloud secrets versions add redis-auth --project="${PROJECT_ID}" --data-file=- \
    || fail 5 "populating redis-auth secret failed."

  log "Adding resend-api-key secret version (value never echoed or passed as an argument)..."
  printf '%s' "${RESEND_API_KEY}" | gcloud secrets versions add resend-api-key --project="${PROJECT_ID}" --data-file=- \
    || fail 5 "populating resend-api-key secret failed."
  RESEND_API_KEY=""

  for secret in redis-auth resend-api-key; do
    local enabled_count
    enabled_count="$(gcloud secrets versions list "${secret}" --project="${PROJECT_ID}" \
      --filter='state=ENABLED' --format='value(name)' | wc -l | tr -d ' ')"
    if [[ "${enabled_count}" -ne 1 ]]; then
      fail 5 "expected exactly 1 ENABLED version for secret '${secret}', found ${enabled_count}."
    fi
    log "Verified: ${secret} has exactly 1 ENABLED version."
  done

  t1=$(date +%s); record_elapsed 5 "Secret values" "$((t1 - t0))"
}

# ─── PHASE 6 — Main apply (+ 6b corrective deploy) ──────────────────────
phase6() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 6 — Main apply"

  local apply_args=(-var-file="${TFVARS_NAME}")
  [[ "${AUTO_YES}" -eq 1 ]] && apply_args+=(-auto-approve)

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would run: terraform apply ${apply_args[*]}"
    t1=$(date +%s); record_elapsed 6 "Main apply" "$((t1 - t0))"
    return 0
  fi

  local attempt=1 max_attempts=3
  while true; do
    local apply_log
    apply_log="$(mktemp)"
    if (cd "${TF_DIR}" && terraform apply "${apply_args[@]}") 2>&1 | tee "${apply_log}" | tee -a "${CMDLOG_FILE}"; then
      rm -f "${apply_log}"
      break
    fi
    if grep -qE '412|allowedPolicyMemberDomains|org.?policy' "${apply_log}" && [[ "${attempt}" -lt "${max_attempts}" ]]; then
      log "Main apply hit the expected org-policy propagation 412 (attempt ${attempt}/${max_attempts}) — waiting 60s and retrying..."
      rm -f "${apply_log}"
      attempt=$((attempt + 1))
      sleep 60
      continue
    fi
    rm -f "${apply_log}"
    fail 6 "main apply failed (see ${CMDLOG_FILE} for full output)."
  done

  # PHASE 6b — corrective deploy. VERIFICATION FINDING: terraform/cloud_run.tf
  # hardcodes SPORTSLOT_WORKER_BASE_URL to the live sport-slot-dev URL, not
  # derived from any variable. Terraform's create bakes in that WRONG value
  # for a new environment. Production's own deploy.yml never hits this
  # because CI always runs deploy_cloud_run.sh right after Terraform, which
  # self-corrects the URL via `gcloud run services describe` now that the
  # service exists. Reusing that same existing, already-guarded script here.
  banner "PHASE 6b — Corrective deploy (scripts/deploy_cloud_run.sh)"
  log "Reason: terraform/cloud_run.tf's SPORTSLOT_WORKER_BASE_URL is hardcoded to the"
  log "        live sport-slot-dev URL; only the CI/deploy_cloud_run.sh path corrects it"
  log "        (self-lookup requires the service to already exist)."
  DEPLOY_START_TS="$(timestamp)"
  local deploy_env=(SLOTSENSE_PROJECT="${PROJECT_ID}" SLOTSENSE_REGION="${REGION}"
    SLOTSENSE_ARTIFACT_REPO="${ARTIFACT_REPO_NAME}" SLOTSENSE_BASE_DOMAIN="${BASE_DOMAIN}"
    SLOTSENSE_ADMIN_HOST="${ADMIN_HOST}")
  [[ "${AUTO_YES}" -eq 1 ]] && deploy_env+=(CI=true)
  env "${deploy_env[@]}" "${REPO_ROOT}/scripts/deploy_cloud_run.sh" "${IMAGE_TAG}" \
    || fail 6 "corrective deploy_cloud_run.sh failed."

  t1=$(date +%s); record_elapsed 6 "Main apply + corrective deploy" "$((t1 - t0))"
}

# ─── PHASE 7 — Application enablement ───────────────────────────────────
phase7() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 7 — Application enablement"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would deploy firestore rules+indexes, build+deploy frontend, seed platform admin."
    t1=$(date +%s); record_elapsed 7 "Application enablement" "$((t1 - t0))"
    return 0
  fi

  log "7a) Deploying Firestore rules + indexes..."
  firebase deploy --only firestore:rules,firestore:indexes --project "${PROJECT_ID}" \
    || fail 7 "firestore rules/indexes deploy failed."

  log "7b) Building + deploying frontend..."
  (cd "${REPO_ROOT}/frontend" && pnpm install --frozen-lockfile && pnpm build) \
    || fail 7 "frontend build failed."

  log "    Deploying Firebase Hosting (scripts/deploy_hosting_rest.sh, project-parameterized)..."
  FIREBASE_PROJECT="${PROJECT_ID}" "${REPO_ROOT}/scripts/deploy_hosting_rest.sh" \
    || fail 7 "Firebase Hosting deploy failed."

  log "    Syncing frontend/dist to gs://${PROJECT_ID}-frontend (same grouping as .github/workflows/deploy.yml)..."
  local bucket="gs://${PROJECT_ID}-frontend"
  local dist="${REPO_ROOT}/frontend/dist"

  gcloud storage cp \
    "${dist}/index.html" "${dist}/manifest.webmanifest" "${dist}/sw.js" "${dist}/registerSW.js" \
    "${bucket}/" --cache-control="no-cache" \
    || fail 7 "GCS sync (no-cache group) failed."
  gcloud storage cp "${dist}"/workbox-*.js "${bucket}/" --cache-control="no-cache" \
    || fail 7 "GCS sync (workbox) failed."
  gcloud storage cp --cache-control="public, max-age=31536000, immutable" \
    "${dist}"/assets/* "${bucket}/assets/" \
    || fail 7 "GCS sync (assets) failed."
  gcloud storage cp \
    "${dist}/favicon-32x32.png" "${dist}/pwa-192x192.png" "${dist}/pwa-512x512.png" "${dist}/pwa-maskable-512x512.png" \
    "${bucket}/" --cache-control="public, max-age=86400" \
    || fail 7 "GCS sync (icons) failed."

  log "7c) Seeding platform admin..."
  local seed_log
  seed_log="$(mktemp)"
  (cd "${REPO_ROOT}/backend" && uv run python scripts/seed_platform_admin.py --project "${PROJECT_ID}") \
    | tee "${seed_log}" | tee -a "${CMDLOG_FILE}" || fail 7 "seed_platform_admin.py failed."

  ADMIN_EMAIL_CAPTURED="$(grep -oE 'admin: [^ ]+@[^ ]+' "${seed_log}" | head -n1 | awk '{print $2}')"
  ADMIN_EMAIL_CAPTURED="${ADMIN_EMAIL_CAPTURED:-admin@chandraailabs.com}"
  ADMIN_TEMP_PASSWORD="$(grep 'Temp password:' "${seed_log}" | head -n1 | sed 's/.*Temp password: //')"
  [[ -n "${ADMIN_TEMP_PASSWORD}" ]] || fail 7 "could not capture temp password from seed_platform_admin.py output — check ${seed_log} manually, then rotate it once retrieved."
  rm -f "${seed_log}"
  state_set CACHED_ADMIN_EMAIL "${ADMIN_EMAIL_CAPTURED}"

  t1=$(date +%s); record_elapsed 7 "Application enablement" "$((t1 - t0))"
}

# ─── PHASE 8 — Verification ──────────────────────────────────────────────
VERIFY_RESULTS=()

phase8() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 8 — Verification"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would verify: latest revision Ready+100% traffic, zero WARNING+ logs since deploy, terraform plan = No changes."
    t1=$(date +%s); record_elapsed 8 "Verification" "$((t1 - t0))"
    return 0
  fi

  local overall_ok=1

  log "Checking newest Cloud Run revision is Ready and serving 100% traffic..."
  local ready traffic_pct
  ready="$(gcloud run services describe sport-slot-api --project="${PROJECT_ID}" --region="${REGION}" \
    --format='value(status.conditions[0].status)' 2>/dev/null || true)"
  traffic_pct="$(gcloud run services describe sport-slot-api --project="${PROJECT_ID}" --region="${REGION}" \
    --format='value(status.traffic[0].percent)' 2>/dev/null || true)"
  if [[ "${ready}" == "True" && "${traffic_pct}" == "100" ]]; then
    VERIFY_RESULTS+=("PASS: newest revision Ready, 100% traffic")
    log "PASS: newest revision Ready, 100% traffic"
  else
    VERIFY_RESULTS+=("FAIL: newest revision Ready='${ready}' traffic='${traffic_pct}'")
    log "FAIL: newest revision Ready='${ready}' traffic='${traffic_pct}'"
    overall_ok=0
  fi

  log "Checking Cloud Run logs since deploy for WARNING+ entries..."
  local warn_count
  warn_count="$(gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=sport-slot-api AND severity>=WARNING AND timestamp>=\"${DEPLOY_START_TS}\"" \
    --project="${PROJECT_ID}" --format='value(timestamp)' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${warn_count}" -eq 0 ]]; then
    VERIFY_RESULTS+=("PASS: zero WARNING+ log entries since deploy")
    log "PASS: zero WARNING+ log entries since deploy"
  else
    VERIFY_RESULTS+=("FAIL: ${warn_count} WARNING+ log entries since deploy")
    log "FAIL: ${warn_count} WARNING+ log entries since deploy"
    overall_ok=0
  fi

  log "Checking terraform plan shows no changes..."
  local plan_exit=0
  (cd "${TF_DIR}" && terraform plan -var-file="${TFVARS_NAME}" -detailed-exitcode) \
    >>"${CMDLOG_FILE}" 2>&1 || plan_exit=$?
  if [[ "${plan_exit}" -eq 0 ]]; then
    VERIFY_RESULTS+=("PASS: terraform plan shows no changes")
    log "PASS: terraform plan shows no changes"
  else
    VERIFY_RESULTS+=("FAIL: terraform plan exited ${plan_exit} (0=no changes, 2=changes pending) — see ${CMDLOG_FILE}")
    log "FAIL: terraform plan exited ${plan_exit} — see ${CMDLOG_FILE}"
    overall_ok=0
  fi

  t1=$(date +%s); record_elapsed 8 "Verification" "$((t1 - t0))"

  if [[ "${overall_ok}" -ne 1 ]]; then
    fail 8 "one or more verification checks failed — see results above. Not claiming success."
  fi
}

# ─── PHASE 9 — Output manifest ──────────────────────────────────────────
phase9() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 9 — Output manifest"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would write ${OUTPUT_FILE}"
    t1=$(date +%s); record_elapsed 9 "Output manifest" "$((t1 - t0))"
    return 0
  fi

  local lb_ip cname_name cname_data run_url
  lb_ip="$(gcloud compute addresses describe slotsense-lb-ip --global --project="${PROJECT_ID}" \
    --format='value(address)' 2>/dev/null || echo 'UNKNOWN — run: gcloud compute addresses describe slotsense-lb-ip --global --project='"${PROJECT_ID}")"
  cname_name="$(gcloud certificate-manager dns-authorizations describe slotsense-dns-auth --project="${PROJECT_ID}" \
    --format='value(dnsResourceRecord.name)' 2>/dev/null || echo 'UNKNOWN')"
  cname_data="$(gcloud certificate-manager dns-authorizations describe slotsense-dns-auth --project="${PROJECT_ID}" \
    --format='value(dnsResourceRecord.data)' 2>/dev/null || echo 'UNKNOWN')"
  run_url="$(gcloud run services describe sport-slot-api --project="${PROJECT_ID}" --region="${REGION}" \
    --format='value(status.url)' 2>/dev/null || echo 'UNKNOWN')"

  local total_seconds=0
  local timing_table=""
  if [[ -f "${TIMING_FILE}" ]]; then
    while IFS='|' read -r label secs_raw; do
      local secs="${secs_raw%s}"
      total_seconds=$((total_seconds + secs))
      timing_table="${timing_table}| ${label} | ${secs}s |
"
    done < "${TIMING_FILE}"
  fi

  {
    echo "# SlotSense drill-bootstrap output — ${PROJECT_ID}"
    echo ""
    echo "Generated: $(timestamp)"
    echo ""
    echo "## WARNING"
    echo ""
    echo "This file contains a temporary platform-admin password. Move it to a"
    echo "password manager and DELETE this file once done."
    echo ""
    echo "## Inputs used"
    echo ""
    echo "| Key | Value |"
    echo "|---|---|"
    echo "| project_id | ${PROJECT_ID} |"
    echo "| project_number | ${PROJECT_NUMBER} |"
    echo "| region | ${REGION} |"
    echo "| zone | ${ZONE} (decorative for Redis — location_id is hardcoded in base_infra.tf) |"
    echo "| environment | ${ENVIRONMENT} |"
    echo "| base_domain | ${BASE_DOMAIN} |"
    echo "| admin_host | ${ADMIN_HOST} |"
    echo "| artifact_repo_name | ${ARTIFACT_REPO_NAME} |"
    echo "| org_id | ${ORG_ID} |"
    echo "| billing_account_id | ${BILLING_ACCOUNT} |"
    echo "| image_tag | ${IMAGE_TAG} |"
    echo ""
    echo "## Load balancer"
    echo ""
    echo "- LB static IP: **${lb_ip}**"
    echo "- DNS records to create at Namecheap:"
    echo "  - Wildcard A record: \`*.${BASE_DOMAIN}\` -> ${lb_ip}"
    echo "  - Certificate Manager DNS authorization CNAME: \`${cname_name}\` -> \`${cname_data}\` (must remain permanently — required for cert renewal)"
    echo ""
    echo "## Cloud Run"
    echo ""
    echo "- Service URL: ${run_url}"
    echo ""
    echo "## Platform admin"
    echo ""
    echo "- Email: ${ADMIN_EMAIL_CAPTURED:-admin@chandraailabs.com}"
    echo "- Temp password: ${ADMIN_TEMP_PASSWORD:-<not captured — check command log>}"
    echo "- Move this to a password manager immediately, then delete this file."
    echo ""
    echo "## scripts/tf.sh registry entry (add manually to scripts/tf.sh's env_lookup())"
    echo ""
    echo '```'
    echo "    ${ENVIRONMENT})"
    echo "      ENV_PROJECT_ID=\"${PROJECT_ID}\""
    echo "      ENV_BUCKET=\"${STATE_BUCKET}\""
    echo "      ENV_PREFIX=\"terraform/state\""
    echo "      ENV_VARFILE=\"${TFVARS_NAME}\""
    echo "      ;;"
    echo '```'
    echo ""
    echo "Also add \"${ENVIRONMENT}\" to ENV_NAMES in the same file."
    echo ""
    echo "## Remaining manual steps"
    echo ""
    echo "- DNS: create the two records above at Namecheap; wait for propagation."
    echo "- Certificate issuance: wait for the wildcard cert to go ACTIVE after DNS authorization resolves."
    echo "- SMS alert channel (optional): create 'Coordinator SMS' in Console, verify phone,"
    echo "  then set enable_sms_alerts = true in ${TFVARS_NAME} and re-apply."
    echo "- Per-env CI wiring: this environment is not yet wired into .github/workflows/deploy.yml."
    echo "- Add the scripts/tf.sh registry entry above."
    echo ""
    echo "## Per-phase elapsed times (measured RTO)"
    echo ""
    echo "| Phase | Elapsed |"
    echo "|---|---|"
    printf '%s' "${timing_table}"
    echo "| **Total** | **$((total_seconds / 60))m $((total_seconds % 60))s** |"
  } > "${OUTPUT_FILE}"

  chmod 600 "${OUTPUT_FILE}"
  log "Wrote ${OUTPUT_FILE}"

  t1=$(date +%s); record_elapsed 9 "Output manifest" "$((t1 - t0))"
}

# ─── Main ────────────────────────────────────────────────────────────────
main() {
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    require_bin gcloud
    require_bin terraform
    require_bin firebase
    require_bin jq
    require_bin pnpm
    require_bin uv
  fi

  phase0
  [[ "${START_PHASE}" -le 1 ]] && phase1
  [[ "${START_PHASE}" -le 2 ]] && phase2
  [[ "${START_PHASE}" -le 3 ]] && phase3
  [[ "${START_PHASE}" -le 4 ]] && phase4
  [[ "${START_PHASE}" -le 5 ]] && phase5
  [[ "${START_PHASE}" -le 6 ]] && phase6
  [[ "${START_PHASE}" -le 7 ]] && phase7
  [[ "${START_PHASE}" -le 8 ]] && phase8
  [[ "${START_PHASE}" -le 9 ]] && phase9

  banner "DONE"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry run complete — no gcloud/terraform/firebase calls were made."
  else
    log "Environment build complete. See ${OUTPUT_FILE} for the full manifest."
  fi
}

main
