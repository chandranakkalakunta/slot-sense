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
#
# Intentional legacy resource names: this script hardcodes
# sport-slot-redis, sport-slot-api, and (as the default artifact repo)
# slot-sense-repo in several gcloud/terraform invocations below. The
# sport-slot -> slot-sense migration renames PROJECT_ID, not the
# terraform-owned resource names inside any given project — those stay
# fixed regardless of which environment they're created in. Do not
# "fix" these to track project_id.

set -euo pipefail

# ─── Paths ──────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# ─── Defaults (Phase 0) ─────────────────────────────────────────────────
DEFAULT_REGION="asia-south1"
DEFAULT_ZONE="asia-south1-c" # NOTE: decorative for Redis — see report; base_infra.tf
                              # hardcodes location_id="asia-south1-c" independent of this var.
# Fallback only when environment is unknown; after --environment is set,
# derive_default_base_domain applies ADR-0046 per-env bases.
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
FIREBASE_WEB_CONFIG_FILE=""
PUBLIC_HOST_LABEL=""
REGISTRY_ENV_NAME=""
BASE_DOMAIN_EXPLICIT=0
ADMIN_HOST_EXPLICIT=0
ADMIN_EMAIL_CAPTURED=""
ADMIN_TEMP_PASSWORD=""

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

# ─── Multi-env host + registry helpers (ADR-0046) ───────────────────────
# One base domain per environment — each has its own wildcard cert + A:
#
#   dev  → slotsense-dev.chandraailabs.com
#   test → slotsense-test.chandraailabs.com
#   prod → slotsense.chandraailabs.com
#
# Hosts under that base (no env slug suffixes):
#   Platform admin: admin.<base_domain>
#   Tenants:        {slug}.<base_domain>   e.g. rvrg.slotsense-test.…
#
# DNS per env (Namecheap host under chandraailabs.com):
#   *.<base_label>  A → this env's LB IP
#   <base_label>    A → this env's LB IP
#   admin.<base_label> A → this env's LB IP (optional if wildcard covers it)
#   _acme-challenge.<base_label> CNAME → Certificate Manager (permanent)
#
# Bootstrap never invents demo tenant names. Pattern B (admin-test / rvrg-test
# under a shared *.slotsense) is retired.
derive_default_base_domain() {
  case "$1" in
    dev) echo "slotsense-dev.chandraailabs.com" ;;
    test) echo "slotsense-test.chandraailabs.com" ;;
    prod-india|prod-uae) echo "slotsense.chandraailabs.com" ;;
    *) echo "slotsense.chandraailabs.com" ;;
  esac
}

derive_public_host_label() {
  # Health-check host left-label = platform admin (no tenant).
  echo "admin"
}

# Admin is always admin.<base_domain> once base is per-env (ADR-0046).
derive_admin_host() {
  local _env="$1" base="$2"
  echo "admin.${base}"
}

# scripts/tf.sh registry key: sport-slot-dev → "dev"; slot-sense-dev-03 → "dev-03".
derive_registry_env_name() {
  local project_id="$1"
  if [[ "${project_id}" == "sport-slot-dev" ]]; then
    echo "dev"
  elif [[ "${project_id}" == slot-sense-* ]]; then
    echo "${project_id#slot-sense-}"
  else
    echo "${project_id}"
  fi
}

# gcloud user ADC often needs an explicit quota project for Firebase REST.
gcp_access_token() {
  gcloud auth print-access-token
}

firebase_rest() {
  # firebase_rest METHOD URL [curl -d args...]
  local method="$1" url="$2"
  shift 2
  local token
  token="$(gcp_access_token)" || return 1
  curl -sS -X "${method}" \
    -H "Authorization: Bearer ${token}" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${url}"
}

wait_firebase_operation() {
  local op_name="$1" deadline=180 waited=0
  local op_json done
  while [[ ${waited} -lt ${deadline} ]]; do
    op_json="$(firebase_rest GET "https://firebase.googleapis.com/v1beta1/${op_name}")" || return 1
    done="$(echo "${op_json}" | jq -r '.done // false')"
    if [[ "${done}" == "true" ]]; then
      if echo "${op_json}" | jq -e '.error' >/dev/null 2>&1; then
        log "Firebase operation failed: $(echo "${op_json}" | jq -c '.error')"
        return 1
      fi
      echo "${op_json}"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "Firebase operation timed out after ${deadline}s: ${op_name}"
  return 1
}

# Ground-truth: is Firebase enabled on THIS project?
# Prefer Firebase Management REST (gcloud ADC) over `firebase projects:list
# | grep` — the CLI list is eventually consistent and can miss a project
# for tens of seconds right after addfirebase (live: slot-sense-test-01
# 2026-08-01 — addfirebase printed success, then Phase 2 failed verify).
# Retries with backoff so a brief propagation lag is not fatal.
verify_firebase_on_project() {
  local project="$1"
  local attempt=1 max_attempts=12 sleep_s=5
  local body state

  while [[ ${attempt} -le ${max_attempts} ]]; do
    body="$(firebase_rest GET "https://firebase.googleapis.com/v1beta1/projects/${project}" 2>/dev/null || true)"
    state="$(echo "${body}" | jq -r '.state // empty' 2>/dev/null || true)"
    if [[ "${state}" == "ACTIVE" ]] \
      && echo "${body}" | jq -e --arg p "${project}" '.projectId == $p' >/dev/null 2>&1; then
      log "Verified Firebase ACTIVE on ${project} via Management API (attempt ${attempt})."
      return 0
    fi
    # Secondary signal: CLI list (may still lag; never the sole attempt-1 check).
    if firebase projects:list 2>/dev/null | grep -F "${project}" >/dev/null 2>&1; then
      log "Verified Firebase on ${project} via firebase projects:list (attempt ${attempt})."
      return 0
    fi
    log "Firebase not yet visible on ${project} (attempt ${attempt}/${max_attempts}); waiting ${sleep_s}s..."
    sleep "${sleep_s}"
    attempt=$((attempt + 1))
  done
  log "Last Management API body: ${body:-<empty>}"
  return 1
}

# Ensure a WEB app exists and write its public SDK config to
# FIREBASE_WEB_CONFIG_FILE. Idempotent. Uses Firebase Management REST
# (gcloud ADC) so a mid-run firebase CLI token expiry cannot skip this.
ensure_firebase_web_app_config() {
  local cfg="${FIREBASE_WEB_CONFIG_FILE}"
  local list_json app_id create_json op_name op_json config_json

  [[ -n "${cfg}" ]] || { log "FIREBASE_WEB_CONFIG_FILE unset"; return 1; }

  if [[ -f "${cfg}" ]]; then
    if jq -e --arg p "${PROJECT_ID}" '.projectId == $p and .apiKey and .appId' "${cfg}" >/dev/null 2>&1; then
      log "Reusing cached Firebase web config at ${cfg}"
      return 0
    fi
    log "Cached Firebase web config missing/stale — refreshing."
  fi

  log "Listing Firebase web apps on ${PROJECT_ID}..."
  list_json="$(firebase_rest GET "https://firebase.googleapis.com/v1beta1/projects/${PROJECT_ID}/webApps")" \
    || { log "Failed to list Firebase web apps"; return 1; }
  if echo "${list_json}" | jq -e '.error' >/dev/null 2>&1; then
    log "List web apps error: $(echo "${list_json}" | jq -c '.error')"
    return 1
  fi

  app_id="$(echo "${list_json}" | jq -r '.apps[0].appId // empty')"
  if [[ -z "${app_id}" ]]; then
    log "No web app on ${PROJECT_ID} — creating 'SlotSense Web'..."
    create_json="$(firebase_rest POST "https://firebase.googleapis.com/v1beta1/projects/${PROJECT_ID}/webApps" \
      -d '{"displayName":"SlotSense Web"}')" \
      || { log "Failed to create Firebase web app"; return 1; }
    if echo "${create_json}" | jq -e '.error' >/dev/null 2>&1; then
      log "Create web app error: $(echo "${create_json}" | jq -c '.error')"
      return 1
    fi
    # Immediate response may already be the WebApp, or a long-running Operation.
    app_id="$(echo "${create_json}" | jq -r '.appId // empty')"
    if [[ -z "${app_id}" ]]; then
      op_name="$(echo "${create_json}" | jq -r '.name // empty')"
      [[ -n "${op_name}" ]] || { log "Create web app returned neither appId nor operation name: ${create_json}"; return 1; }
      log "Waiting for web app create operation: ${op_name}"
      op_json="$(wait_firebase_operation "${op_name}")" || return 1
      app_id="$(echo "${op_json}" | jq -r '.response.appId // empty')"
      [[ -n "${app_id}" ]] || { log "Operation completed without appId: ${op_json}"; return 1; }
    fi
    log "Created Firebase web app: ${app_id}"
  else
    log "Found existing Firebase web app: ${app_id}"
  fi

  log "Fetching Firebase web SDK config for ${app_id}..."
  config_json="$(firebase_rest GET "https://firebase.googleapis.com/v1beta1/projects/${PROJECT_ID}/webApps/${app_id}/config")" \
    || { log "Failed to fetch web SDK config"; return 1; }
  if echo "${config_json}" | jq -e '.error' >/dev/null 2>&1; then
    log "SDK config error: $(echo "${config_json}" | jq -c '.error')"
    return 1
  fi
  if ! echo "${config_json}" | jq -e --arg p "${PROJECT_ID}" \
      '.projectId == $p and .apiKey and .appId and .authDomain' >/dev/null 2>&1; then
    log "SDK config incomplete or wrong project: ${config_json}"
    return 1
  fi

  umask 077
  echo "${config_json}" | jq '.' > "${cfg}"
  chmod 600 "${cfg}"
  log "Wrote Firebase web config → ${cfg}"
}

# Build frontend with target-project VITE_FIREBASE_* (shell env wins over
# committed frontend/.env.production). Fails if dist still embeds the wrong
# projectId — the exact gap that made dev-03 login against sport-slot-dev.
build_frontend_for_project() {
  local cfg="${FIREBASE_WEB_CONFIG_FILE}"
  local api_key auth_domain project_id storage_bucket messaging_sender_id app_id
  local dist_js

  [[ -f "${cfg}" ]] || { log "Missing Firebase web config ${cfg}"; return 1; }

  api_key="$(jq -r '.apiKey' "${cfg}")"
  auth_domain="$(jq -r '.authDomain' "${cfg}")"
  project_id="$(jq -r '.projectId' "${cfg}")"
  storage_bucket="$(jq -r '.storageBucket' "${cfg}")"
  messaging_sender_id="$(jq -r '.messagingSenderId' "${cfg}")"
  app_id="$(jq -r '.appId' "${cfg}")"

  [[ "${project_id}" == "${PROJECT_ID}" ]] \
    || { log "Config projectId '${project_id}' != target '${PROJECT_ID}'"; return 1; }

  # ADR-0046: host↔claim redirects and tenantSlugFromHost use VITE_BASE_DOMAIN.
  # Without it the SPA falls back to prod apex; admin.slotsense-test… is treated
  # as an unknown host (slug=null) and tenant redirect is skipped entirely.
  log "Building frontend with VITE_FIREBASE_PROJECT_ID=${project_id} VITE_BASE_DOMAIN=${BASE_DOMAIN}..."
  (
    cd "${REPO_ROOT}/frontend"
    pnpm install --frozen-lockfile
    VITE_FIREBASE_API_KEY="${api_key}" \
    VITE_FIREBASE_AUTH_DOMAIN="${auth_domain}" \
    VITE_FIREBASE_PROJECT_ID="${project_id}" \
    VITE_FIREBASE_STORAGE_BUCKET="${storage_bucket}" \
    VITE_FIREBASE_MESSAGING_SENDER_ID="${messaging_sender_id}" \
    VITE_FIREBASE_APP_ID="${app_id}" \
    VITE_BASE_DOMAIN="${BASE_DOMAIN}" \
    pnpm build
  ) || return 1

  dist_js="$(ls "${REPO_ROOT}/frontend/dist/assets"/index-*.js 2>/dev/null | head -n1 || true)"
  [[ -n "${dist_js}" ]] || { log "No frontend/dist/assets/index-*.js after build"; return 1; }

  if ! grep -q "projectId:\"${PROJECT_ID}\"" "${dist_js}"; then
    log "FATAL: built frontend does not embed projectId:\"${PROJECT_ID}\" (file: ${dist_js})"
    return 1
  fi
  if [[ "${PROJECT_ID}" != "sport-slot-dev" ]] && grep -q 'projectId:"sport-slot-dev"' "${dist_js}"; then
    log "FATAL: built frontend still embeds sport-slot-dev Firebase config"
    return 1
  fi
  if ! grep -qF "${BASE_DOMAIN}" "${dist_js}"; then
    log "FATAL: built frontend does not embed VITE_BASE_DOMAIN=${BASE_DOMAIN} (file: ${dist_js})"
    return 1
  fi
  log "Frontend build verified: embeds projectId:\"${PROJECT_ID}\" and base domain ${BASE_DOMAIN}"
}

sync_frontend_to_gcs() {
  local bucket="gs://${PROJECT_ID}-frontend"
  local dist="${REPO_ROOT}/frontend/dist"

  log "Syncing frontend/dist to ${bucket}..."
  gcloud storage cp \
    "${dist}/index.html" "${dist}/manifest.webmanifest" "${dist}/sw.js" "${dist}/registerSW.js" \
    "${bucket}/" --cache-control="no-cache" \
    || return 1
  gcloud storage cp "${dist}"/workbox-*.js "${bucket}/" --cache-control="no-cache" \
    || return 1
  gcloud storage cp --cache-control="public, max-age=31536000, immutable" \
    "${dist}"/assets/* "${bucket}/assets/" \
    || return 1
  gcloud storage cp \
    "${dist}/favicon-32x32.png" "${dist}/pwa-192x192.png" "${dist}/pwa-512x512.png" "${dist}/pwa-maskable-512x512.png" \
    "${bucket}/" --cache-control="public, max-age=86400" \
    || return 1
}

# Idempotently register this environment in scripts/tf.sh so subsequent
# terraform work does not require a manual edit for a freshly built env.
#
# NOTE: use POSIX [[:space:]] in awk — NOT \s. macOS / BSD awk does not
# treat \s as whitespace, so /^\s*\*)/ never matched the default arm and
# Phase 7 died with "could not locate ENV_NAMES and/or *) arm" after a
# successful admin seed (slot-sense-test-01, 2026-08-01).
ensure_tf_sh_registry_entry() {
  local tfsh="${REPO_ROOT}/scripts/tf.sh"
  local reg="${REGISTRY_ENV_NAME}"
  local tmp

  [[ -f "${tfsh}" ]] || { log "scripts/tf.sh missing — skip registry update"; return 0; }
  [[ -n "${reg}" ]] || { log "REGISTRY_ENV_NAME empty — skip registry update"; return 0; }

  if grep -qE "^[[:space:]]*${reg}\\)" "${tfsh}"; then
    log "scripts/tf.sh already registers '${reg}' — leave as-is."
    return 0
  fi

  log "Adding scripts/tf.sh registry entry for '${reg}' → ${PROJECT_ID}"
  tmp="$(mktemp)"
  awk -v reg="${reg}" -v project="${PROJECT_ID}" -v bucket="${STATE_BUCKET}" -v varfile="${TFVARS_NAME}" '
    BEGIN { added_names=0; added_case=0 }
    /^ENV_NAMES=/ && !added_names {
      # Append the new env name inside the quoted list (before closing ").
      if (index($0, reg) == 0) {
        sub(/"$/, " " reg "\"")
      }
      added_names=1
    }
    /^[[:space:]]*\*\)/ && !added_case {
      print "    " reg ")"
      print "      ENV_PROJECT_ID=\"" project "\""
      print "      ENV_BUCKET=\"" bucket "\""
      print "      ENV_PREFIX=\"terraform/state\""
      print "      ENV_VARFILE=\"" varfile "\""
      print "      ;;"
      added_case=1
    }
    { print }
    END {
      if (!added_names || !added_case) {
        print "ERROR: could not locate ENV_NAMES and/or *) arm in scripts/tf.sh" > "/dev/stderr"
        print "  (hint: awk must match /^[[:space:]]*\\*)/ — \\s is not portable)" > "/dev/stderr"
        exit 1
      }
    }
  ' "${tfsh}" > "${tmp}" || return 1
  mv "${tmp}" "${tfsh}"
  chmod 755 "${tfsh}"
  log "Registered '${reg}' in scripts/tf.sh (commit this change with the env PR)."
}

# ─── Usage ────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
drill-bootstrap.sh — single-command SlotSense environment build (PR-G / PR-L)

Builds a complete environment (project → Terraform → Firebase Auth web app →
frontend wired to THAT project's Firebase → admin seed → verify) for any of
dev | test | prod-india | prod-uae. Idempotent and --start-phase resumable.

Usage:
  scripts/drill-bootstrap.sh [options]

Options:
  --project-id ID            GCP project id (required; see naming rule below)
  --region REGION            asia-south1 | asia-southeast1 | europe-west1 | us-central1
                              (default: asia-south1)
  --zone ZONE                Zonal default for the provider block (default: asia-south1-c)
  --environment ENV          dev | test | prod-india | prod-uae
  --base-domain DOMAIN       ADR-0046 default by --environment:
                              dev→slotsense-dev.*  test→slotsense-test.*
                              prod→slotsense.*
  --admin-host HOST          default: admin.<base-domain>
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

What this script NOW wires automatically (no manual console steps):
  - Firebase project + Email/Password (Terraform auth.tf)
  - Firebase WEB app + public SDK config
  - Frontend build with VITE_FIREBASE_* for the target project (verified in dist)
  - Hosting deploy + GCS frontend bucket sync
  - Platform admin seed against --project
  - scripts/tf.sh registry entry for the new env

Still manual after the run (external / human-gated):
  - Namecheap DNS A + cert CNAME (see manifest)
  - Password-manager capture of the temp admin password
  - Per-env GitHub Actions deploy.yml wiring (optional until CI targets this env)
  - Commit of the scripts/tf.sh registry edit

Examples:
  scripts/drill-bootstrap.sh --project-id slot-sense-test-01 --environment test --yes
  scripts/drill-bootstrap.sh --project-id slot-sense-dev-03 --environment dev --dry-run
  scripts/drill-bootstrap.sh --project-id slot-sense-dev-03 --start-phase 7 --yes

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
    --base-domain) BASE_DOMAIN="$2"; BASE_DOMAIN_EXPLICIT=1; shift 2 ;;
    --admin-host) ADMIN_HOST="$2"; ADMIN_HOST_EXPLICIT=1; shift 2 ;;
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
  FIREBASE_WEB_CONFIG_FILE="${REPO_ROOT}/.drill-firebase-web-config-${PROJECT_ID}.json"
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
  if [[ "${BASE_DOMAIN_EXPLICIT}" -eq 0 && -n "${CACHED_BASE_DOMAIN:-}" ]]; then
    BASE_DOMAIN="${CACHED_BASE_DOMAIN}"
  fi
  if [[ "${ADMIN_HOST_EXPLICIT}" -eq 0 ]]; then
    if [[ -n "${CACHED_ADMIN_HOST:-}" ]]; then
      ADMIN_HOST="${CACHED_ADMIN_HOST}"
    fi
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
  PUBLIC_HOST_LABEL="${CACHED_PUBLIC_HOST_LABEL:-}"
  REGISTRY_ENV_NAME="${CACHED_REGISTRY_ENV_NAME:-}"

  validate_region "${REGION}" || fail 0 "invalid region."

  if [[ -z "${ENVIRONMENT}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      fail 0 "--non-interactive requires --environment."
    fi
    read -r -p "environment (dev|test|prod-india|prod-uae): " ENVIRONMENT
  fi
  validate_environment "${ENVIRONMENT}" || fail 0 "invalid environment."

  # ADR-0046: default base domain from environment unless operator/cache pinned it.
  if [[ "${BASE_DOMAIN_EXPLICIT}" -eq 0 && -z "${CACHED_BASE_DOMAIN:-}" ]]; then
    BASE_DOMAIN="$(derive_default_base_domain "${ENVIRONMENT}")"
  fi

  # Derive hosts under the per-env base (admin.<base>, not Pattern-B admin-test).
  PUBLIC_HOST_LABEL="${PUBLIC_HOST_LABEL:-$(derive_public_host_label "${ENVIRONMENT}")}"
  REGISTRY_ENV_NAME="${REGISTRY_ENV_NAME:-$(derive_registry_env_name "${PROJECT_ID}")}"
  if [[ "${ADMIN_HOST_EXPLICIT}" -eq 0 && -z "${CACHED_ADMIN_HOST:-}" ]]; then
    ADMIN_HOST="$(derive_admin_host "${ENVIRONMENT}" "${BASE_DOMAIN}")"
  fi

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
  printf '  %-20s %s\n' "public_host:" "${PUBLIC_HOST_LABEL}.${BASE_DOMAIN}"
  printf '  %-20s %s\n' "admin_host:" "${ADMIN_HOST}"
  printf '  %-20s %s\n' "tf.sh registry:" "${REGISTRY_ENV_NAME}"
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
  state_set CACHED_PUBLIC_HOST_LABEL "${PUBLIC_HOST_LABEL}"
  state_set CACHED_REGISTRY_ENV_NAME "${REGISTRY_ENV_NAME}"
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
    || log "INFO: could not set ADC quota project (already checked healthy in Phase 0 preflight)."

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
    log "[dry-run] would ensure a Firebase WEB app exists and cache its SDK config to"
    log "[dry-run]   ${FIREBASE_WEB_CONFIG_FILE}"
    t1=$(date +%s); record_elapsed 2 "Firebase" "$((t1 - t0))"
    return 0
  fi

  log "Running: firebase projects:addfirebase ${PROJECT_ID}"
  firebase projects:addfirebase "${PROJECT_ID}" 2>&1 | tee -a "${CMDLOG_FILE}" || true
  # The command genuinely can exit non-zero on "already added" in some
  # firebase-tools versions — the `|| true` above is deliberate. Wording
  # in its stdout is not a stable success signal across CLI versions
  # (dev-03 drill: WARNING fired despite Firebase being correctly
  # enabled). Verify with Management REST + retries — NOT a single
  # `firebase projects:list | grep` (test-01 2026-08-01: list lagged
  # after a successful addfirebase and false-failed Phase 2).
  verify_firebase_on_project "${PROJECT_ID}" \
    || fail 2 "Firebase resources not detected on project after addfirebase (Management API + projects:list still negative after retries). Check ${CMDLOG_FILE}."

  # WEB app + public SDK config — required so Phase 7 can build the SPA
  # against THIS project rather than the committed frontend/.env.production
  # (which is still sport-slot-dev). Gap found live on dev-03: 0 web apps,
  # SPA baked projectId:"sport-slot-dev", seed password unused.
  ensure_firebase_web_app_config \
    || fail 2 "could not ensure Firebase web app + SDK config for ${PROJECT_ID}."

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
  banner "PHASE 3 — Bootstrap-group apply (API enable + propagation wait + resource creation, ~11 minutes total)"

  local targets_3a=(
    "-target=google_project_service.enabled_apis"
  )
  local targets_3b=(
    "-target=google_artifact_registry_repository.sport_slot_repo"
    "-target=google_project_iam_member.compute_sa_cloudbuild_builder"
    "-target=google_storage_bucket.cloudbuild_staging"
    "-target=google_redis_instance.sport_slot_redis"
    "-target=google_secret_manager_secret.redis_auth"
    "-target=google_secret_manager_secret.resend_api_key"
    "-target=google_service_account.cloud_build"
    "-target=google_project_iam_member.cloud_build_artifactregistry_writer"
    "-target=google_project_iam_member.cloud_build_logging_log_writer"
    "-target=google_project_iam_member.cloud_build_run_developer"
    "-target=google_storage_bucket_iam_member.cloud_build_staging_object_admin"
  )

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    banner "PHASE 3a — API enablement"
    log "[dry-run] would run: terraform apply -var-file=${TFVARS_NAME} -auto-approve ${targets_3a[*]}"
    log "[dry-run] Waiting 60s for Google API propagation"
    banner "PHASE 3b — Resource creation (Redis + Cloud Build SA/IAM + secret shells)"
    log "[dry-run] would run: terraform apply -var-file=${TFVARS_NAME} -auto-approve ${targets_3b[*]}"
    t1=$(date +%s); record_elapsed 3 "Bootstrap-group apply" "$((t1 - t0))"
    return 0
  fi

  banner "PHASE 3a — API enablement"
  log "Running: terraform apply -var-file=${TFVARS_NAME} -auto-approve ${targets_3a[*]}"
  (cd "${TF_DIR}" && terraform apply -var-file="${TFVARS_NAME}" -auto-approve "${targets_3a[@]}") \
    || fail 3 "Phase 3a (API enablement) apply failed."

  log "Waiting 60s for Google API propagation"
  sleep 60

  banner "PHASE 3b — Resource creation (includes Redis — this will take ~9-10 minutes)"
  log "This will take a while (Redis instance creation is ~9-10 minutes). Please wait..."
  (cd "${TF_DIR}" && terraform apply -var-file="${TFVARS_NAME}" -auto-approve "${targets_3b[@]}") \
    || fail 3 "Phase 3b (resource creation) apply failed."

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

  # Intentional fail-loud: this check requires exactly 1 ENABLED version,
  # not "at least 1". On a re-run against an environment that already has
  # a version, silently adding another would leave two ENABLED versions
  # with no automated way to know which one is correct — an automatic
  # double-write here would be worse than stopping and making the
  # operator decide. If a second version is genuinely intended (rotation),
  # disable the prior version (`gcloud secrets versions disable`) and
  # re-run this phase.
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

  local attempt=1 max_attempts=4
  while true; do
    local apply_log
    apply_log="$(mktemp)"
    if (cd "${TF_DIR}" && terraform apply "${apply_args[@]}") 2>&1 | tee "${apply_log}" | tee -a "${CMDLOG_FILE}"; then
      rm -f "${apply_log}"
      break
    fi
    # Org policy allow_public_members can lag → allUsers on frontend bucket 412.
    if grep -qE '412|allowedPolicyMemberDomains|org.?policy' "${apply_log}" && [[ "${attempt}" -lt "${max_attempts}" ]]; then
      log "Main apply hit the expected org-policy propagation 412 (attempt ${attempt}/${max_attempts}) — waiting 60s and retrying..."
      rm -f "${apply_log}"
      attempt=$((attempt + 1))
      sleep 60
      continue
    fi
    # Cloud Run create failed (often secretAccessor race) → resource tainted →
    # next plan wants destroy+recreate but prevent_destroy blocks. Drop the
    # failed service + state entry so the next apply creates cleanly.
    if grep -qE 'prevent_destroy|is tainted, so must be replaced' "${apply_log}" \
      && grep -qE 'google_cloud_run_v2_service\.sport_slot_api|sport_slot_api' "${apply_log}" \
      && [[ "${attempt}" -lt "${max_attempts}" ]]; then
      log "Main apply blocked on tainted Cloud Run + prevent_destroy (attempt ${attempt}/${max_attempts})."
      log "Recovering: delete failed service (if any) and remove from Terraform state, then retry..."
      gcloud run services delete sport-slot-api \
        --project="${PROJECT_ID}" --region="${REGION}" --quiet 2>/dev/null \
        || log "  (no live sport-slot-api to delete — OK)"
      (cd "${TF_DIR}" && terraform state rm 'google_cloud_run_v2_service.sport_slot_api' 2>/dev/null) \
        || log "  (service not in state — OK)"
      rm -f "${apply_log}"
      attempt=$((attempt + 1))
      sleep 15
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
  local app_env="development"
  case "${ENVIRONMENT}" in
    prod-india|prod-uae) app_env="production" ;;
    test) app_env="test" ;;
    *) app_env="development" ;;
  esac
  local deploy_env=(SLOTSENSE_PROJECT="${PROJECT_ID}" SLOTSENSE_REGION="${REGION}"
    SLOTSENSE_ARTIFACT_REPO="${ARTIFACT_REPO_NAME}" SLOTSENSE_BASE_DOMAIN="${BASE_DOMAIN}"
    SLOTSENSE_ADMIN_HOST="${ADMIN_HOST}" SLOTSENSE_APP_ENVIRONMENT="${app_env}")
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
    log "[dry-run] would deploy firestore rules+indexes."
    log "[dry-run] would ensure Firebase web SDK config, build frontend with VITE_FIREBASE_* for ${PROJECT_ID},"
    log "[dry-run]   verify dist embeds projectId:\"${PROJECT_ID}\", deploy Hosting + GCS sync."
    log "[dry-run] would seed platform admin against --project ${PROJECT_ID}."
    log "[dry-run] would ensure scripts/tf.sh registry entry for '${REGISTRY_ENV_NAME}'."
    t1=$(date +%s); record_elapsed 7 "Application enablement" "$((t1 - t0))"
    return 0
  fi

  log "7a) Deploying Firestore rules + indexes..."
  firebase deploy --only firestore:rules,firestore:indexes --project "${PROJECT_ID}" \
    || fail 7 "firestore rules/indexes deploy failed."

  log "7b) Ensuring Firebase web config + building frontend for ${PROJECT_ID}..."
  # Re-ensure on resume-from-7 (Phase 2 may have been skipped).
  ensure_firebase_web_app_config \
    || fail 7 "could not ensure Firebase web app + SDK config for ${PROJECT_ID}."
  build_frontend_for_project \
    || fail 7 "frontend build/verify failed — SPA would not authenticate against ${PROJECT_ID}."

  log "    Deploying Firebase Hosting (scripts/deploy_hosting_rest.sh, project-parameterized)..."
  FIREBASE_PROJECT="${PROJECT_ID}" "${REPO_ROOT}/scripts/deploy_hosting_rest.sh" \
    || fail 7 "Firebase Hosting deploy failed."

  sync_frontend_to_gcs \
    || fail 7 "GCS frontend sync failed."

  log "7c) Seeding platform admin against project ${PROJECT_ID}..."
  # Captured to an ephemeral, 600-permission file only — NEVER to
  # CMDLOG_FILE (persistent, part of the report). seed_platform_admin.py
  # prints the temp password verbatim to stdout; piping that through
  # `tee -a "${CMDLOG_FILE}"` would leave it sitting in a log we keep
  # around, which defeats the point of it being a one-time-print secret.
  local seed_log
  seed_log="$(mktemp)"
  chmod 600 "${seed_log}"
  if ! (cd "${REPO_ROOT}/backend" && uv run python scripts/seed_platform_admin.py --project "${PROJECT_ID}") \
      > "${seed_log}" 2>&1; then
    log "seed_platform_admin.py failed — see ${seed_log}"
    cat "${seed_log}" >&2
    rm -f "${seed_log}"
    fail 7 "seed_platform_admin.py failed."
  fi
  log "seed_platform_admin.py succeeded (output captured to ephemeral file, not persistent log)."

  # Prefer the explicit "platform admin: email" / "Created ... admin: email" lines.
  ADMIN_EMAIL_CAPTURED="$(
    grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${seed_log}" | head -n1 || true
  )"
  ADMIN_EMAIL_CAPTURED="${ADMIN_EMAIL_CAPTURED:-admin@chandraailabs.com}"
  ADMIN_TEMP_PASSWORD="$(grep 'Temp password:' "${seed_log}" | head -n1 | sed 's/.*Temp password: //')"
  [[ -n "${ADMIN_TEMP_PASSWORD}" ]] || fail 7 "could not capture temp password from seed_platform_admin.py output — check ${seed_log} manually, then rotate it once retrieved."
  rm -f "${seed_log}"
  state_set CACHED_ADMIN_EMAIL "${ADMIN_EMAIL_CAPTURED}"

  log "7d) Ensuring scripts/tf.sh registry entry..."
  ensure_tf_sh_registry_entry \
    || fail 7 "could not update scripts/tf.sh registry for '${REGISTRY_ENV_NAME}'."

  t1=$(date +%s); record_elapsed 7 "Application enablement" "$((t1 - t0))"
}

# ─── PHASE 8 — Verification ──────────────────────────────────────────────
# OVERALL_VERIFY_OK is global (not a phase8 local) so main() can read it
# after phase9 has run — Phase 9 MUST always run when Phase 8 was
# entered, even when a check below fails, so the fail-8 decision is
# deferred to main() instead of exiting from inside this function.
VERIFY_RESULTS=()
OVERALL_VERIFY_OK=1

phase8() {
  local t0 t1
  t0=$(date +%s)
  banner "PHASE 8 — Verification"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] would verify: latest revision Ready+100% traffic, frontend GCS embeds projectId,"
    log "[dry-run]   LB /health via Host header, zero WARNING+ logs since deploy, terraform plan = No changes."
    t1=$(date +%s); record_elapsed 8 "Verification" "$((t1 - t0))"
    return 0
  fi

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
    OVERALL_VERIFY_OK=0
  fi

  # Frontend ↔ Auth project wiring (the gap that broke admin login on
  # slot-sense-dev-03). Ground truth = what is actually in the frontend
  # bucket, not what a local dist folder claims.
  log "Checking hosted frontend embeds Firebase projectId=${PROJECT_ID}..."
  local asset_uri asset_tmp hosted_ok=0
  asset_uri="$(gcloud storage ls "gs://${PROJECT_ID}-frontend/assets/index-*.js" 2>/dev/null | head -n1 || true)"
  asset_tmp="$(mktemp)"
  if [[ -n "${asset_uri}" ]] && gcloud storage cat "${asset_uri}" > "${asset_tmp}" 2>/dev/null; then
    if grep -q "projectId:\"${PROJECT_ID}\"" "${asset_tmp}"; then
      if [[ "${PROJECT_ID}" != "sport-slot-dev" ]] && grep -q 'projectId:"sport-slot-dev"' "${asset_tmp}"; then
        VERIFY_RESULTS+=("FAIL: hosted frontend still embeds sport-slot-dev Firebase config")
        log "FAIL: hosted frontend still embeds sport-slot-dev Firebase config (${asset_uri})"
        OVERALL_VERIFY_OK=0
      else
        VERIFY_RESULTS+=("PASS: hosted frontend embeds projectId:\"${PROJECT_ID}\"")
        log "PASS: hosted frontend embeds projectId:\"${PROJECT_ID}\""
        hosted_ok=1
      fi
    else
      VERIFY_RESULTS+=("FAIL: hosted frontend does not embed projectId:\"${PROJECT_ID}\"")
      log "FAIL: hosted frontend does not embed projectId:\"${PROJECT_ID}\" (${asset_uri})"
      OVERALL_VERIFY_OK=0
    fi
  else
    VERIFY_RESULTS+=("FAIL: could not read hosted frontend asset under gs://${PROJECT_ID}-frontend/assets/")
    log "FAIL: could not read hosted frontend asset under gs://${PROJECT_ID}-frontend/assets/"
    OVERALL_VERIFY_OK=0
  fi
  rm -f "${asset_tmp}"

  # LB path (Cloud Run is ingress=internal-and-cloud-load-balancing, so
  # the *.run.app URL is expected to 404 from the public internet).
  log "Checking LB /health via static IP + Host header..."
  local lb_ip health_code
  lb_ip="$(gcloud compute addresses describe slotsense-lb-ip --global --project="${PROJECT_ID}" \
    --format='value(address)' 2>/dev/null || true)"
  if [[ -n "${lb_ip}" ]]; then
    health_code="$(
      curl -sS -o /dev/null -w '%{http_code}' -m 15 -k \
        --resolve "${PUBLIC_HOST_LABEL}.${BASE_DOMAIN}:443:${lb_ip}" \
        "https://${PUBLIC_HOST_LABEL}.${BASE_DOMAIN}/health" 2>/dev/null || echo "000"
    )"
    if [[ "${health_code}" == "200" ]]; then
      VERIFY_RESULTS+=("PASS: LB /health → 200 via Host ${PUBLIC_HOST_LABEL}.${BASE_DOMAIN}")
      log "PASS: LB /health → 200 via Host ${PUBLIC_HOST_LABEL}.${BASE_DOMAIN} (ip ${lb_ip})"
    else
      # Cert may still be provisioning on first build — WARN not FAIL so
      # Phase 9 still writes the DNS records the operator needs.
      VERIFY_RESULTS+=("WARN: LB /health → HTTP ${health_code} (cert/DNS may still be pending — see manifest)")
      log "WARN: LB /health → HTTP ${health_code} via ${PUBLIC_HOST_LABEL}.${BASE_DOMAIN} (ip ${lb_ip}) — DNS/cert may still be pending"
    fi
  else
    VERIFY_RESULTS+=("WARN: could not resolve LB static IP for health check")
    log "WARN: could not resolve LB static IP for health check"
  fi
  # silence unused when shellcheck is strict about hosted_ok
  : "${hosted_ok}"

  # Log check — capture exit status separately so a failed gcloud call
  # doesn't kill the script under pipefail (auth expiry mid-run, logging
  # API not yet queryable on a freshly created project, network hiccup —
  # all observed or plausible on a live drill). Treat "cannot query logs
  # yet" as WARN-and-continue, not fatal.
  log "Checking Cloud Run logs since deploy for WARNING+ entries..."
  local logs_out logs_exit=0
  logs_out="$(mktemp)"
  gcloud logging read \
    "resource.type=cloud_run_revision AND resource.labels.service_name=sport-slot-api AND severity>=WARNING AND timestamp>=\"${DEPLOY_START_TS}\"" \
    --project="${PROJECT_ID}" --format='value(timestamp)' \
    > "${logs_out}" 2>&1 || logs_exit=$?
  if [[ ${logs_exit} -ne 0 ]]; then
    VERIFY_RESULTS+=("WARN: could not query Cloud Run logs (exit ${logs_exit}) — see ${CMDLOG_FILE}")
    log "WARN: could not query Cloud Run logs (exit ${logs_exit}) — continuing to Phase 9"
    cat "${logs_out}" >> "${CMDLOG_FILE}"
  else
    local warn_count
    warn_count="$(wc -l < "${logs_out}" | tr -d ' ')"
    if [[ ${warn_count} -eq 0 ]]; then
      VERIFY_RESULTS+=("PASS: zero WARNING+ log entries since deploy")
      log "PASS: zero WARNING+ log entries since deploy"
    else
      VERIFY_RESULTS+=("FAIL: ${warn_count} WARNING+ log entries since deploy")
      log "FAIL: ${warn_count} WARNING+ log entries since deploy"
      OVERALL_VERIFY_OK=0
    fi
  fi
  rm -f "${logs_out}"

  # Same treatment for the plan check: terraform's own exit codes already
  # distinguish "ran fine, changes pending" (2, a real FAIL) from "crashed"
  # (anything else nonzero — auth expiry, backend transient). Only the
  # crash case is WARN-and-continue.
  log "Checking terraform plan shows no changes..."
  local plan_exit=0
  (cd "${TF_DIR}" && terraform plan -var-file="${TFVARS_NAME}" -detailed-exitcode) \
    >>"${CMDLOG_FILE}" 2>&1 || plan_exit=$?
  case "${plan_exit}" in
    0)
      VERIFY_RESULTS+=("PASS: terraform plan shows no changes")
      log "PASS: terraform plan shows no changes"
      ;;
    2)
      VERIFY_RESULTS+=("FAIL: terraform plan shows pending changes (exit 2) — see ${CMDLOG_FILE}")
      log "FAIL: terraform plan shows pending changes (exit 2) — see ${CMDLOG_FILE}"
      OVERALL_VERIFY_OK=0
      ;;
    *)
      VERIFY_RESULTS+=("WARN: terraform plan could not run cleanly (exit ${plan_exit}) — see ${CMDLOG_FILE}")
      log "WARN: terraform plan could not run cleanly (exit ${plan_exit}) — continuing to Phase 9"
      ;;
  esac

  t1=$(date +%s); record_elapsed 8 "Verification" "$((t1 - t0))"
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

  local public_host="${PUBLIC_HOST_LABEL}.${BASE_DOMAIN}"
  local firebase_app_id="(not cached)"
  if [[ -f "${FIREBASE_WEB_CONFIG_FILE}" ]]; then
    firebase_app_id="$(jq -r '.appId // "(missing)"' "${FIREBASE_WEB_CONFIG_FILE}" 2>/dev/null || echo "(missing)")"
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
    echo "| public_host | ${public_host} |"
    echo "| admin_host | ${ADMIN_HOST} |"
    echo "| tf.sh registry key | ${REGISTRY_ENV_NAME} |"
    echo "| artifact_repo_name | ${ARTIFACT_REPO_NAME} |"
    echo "| org_id | ${ORG_ID} |"
    echo "| billing_account_id | ${BILLING_ACCOUNT} |"
    echo "| image_tag | ${IMAGE_TAG} |"
    echo "| firebase_web_app_id | ${firebase_app_id} |"
    echo ""
    echo "## Login (after DNS)"
    echo ""
    echo "- Platform admin URL (no tenant): \`https://${ADMIN_HOST}\`"
    echo "- Health-check host (same as admin by default): \`https://${public_host}\`"
    echo "- Firebase Auth project: **${PROJECT_ID}** (frontend is built against this — not sport-slot-dev)"
    echo "- Platform admin email: \`${ADMIN_EMAIL_CAPTURED:-admin@chandraailabs.com}\`"
    echo "- Temp password: \`${ADMIN_TEMP_PASSWORD:-<not captured — re-run seed_platform_admin.py --project ${PROJECT_ID}>}\`"
    echo "- Sign in **fresh** (sign-out first if any old session); custom claims only appear on a new ID token."
    echo "- Tenant hosts need **no per-tenant DNS** (ADR-0046). After you create a tenant with slug"
    echo "  e.g. \`rvrg\`, open \`https://rvrg.${BASE_DOMAIN}\` — covered by the env wildcard A."
    echo ""
    echo "## Load balancer + DNS (manual — external registrar; ADR-0046)"
    echo ""
    echo "- LB static IP for **this** environment only: **${lb_ip}**"
    echo "- Each env has its **own** base domain and wildcard A → **this** IP only."
    echo "- Namecheap records for this env (domain = parent of \`${BASE_DOMAIN}\`):"
    echo "  - A: \`*.<base_label>\` → \`${lb_ip}\`  (all tenants + admin if not separate)"
    echo "  - A: \`<base_label>\` → \`${lb_ip}\`  (apex)"
    echo "  - A: \`admin.<base_label>\` → \`${lb_ip}\`  (platform admin; optional if wildcard covers it)"
    echo "  - CNAME (permanent, cert renewal): \`${cname_name}\` → \`${cname_data}\`"
    echo "- Do **not** share one \`*.slotsense\` A across dev/test/prod — that routes all envs to one LB."
    echo "- Wildcard cert covers \`*.${BASE_DOMAIN}\` + apex; ACME CNAME must stay forever."
    echo "- After DNS: \`curl -sf https://${ADMIN_HOST}/health\` → \`{\"status\":\"ok\"}\`"
    echo ""
    echo "## Cloud Run"
    echo ""
    echo "- Service URL (internal/LB only — public *.run.app /health is expected to 404): ${run_url}"
    echo "- \`SPORTSLOT_GCP_PROJECT\` must be \`${PROJECT_ID}\` (set by Terraform + deploy_cloud_run.sh)."
    echo ""
    echo "## scripts/tf.sh registry"
    echo ""
    echo "The bootstrap script **auto-registers** \`${REGISTRY_ENV_NAME}\` in \`scripts/tf.sh\` when missing."
    echo "Commit that file change with the environment PR:"
    echo ""
    echo '```'
    echo "scripts/tf.sh ${REGISTRY_ENV_NAME} plan"
    echo '```'
    echo ""
    echo "## Remaining manual steps"
    echo ""
    echo "1. Copy admin email + temp password into the password manager; **delete this file**."
    echo "2. Create the DNS records above; wait for cert ACTIVE if first env on this domain."
    echo "3. Commit \`scripts/tf.sh\` registry edit (if the run added one)."
    echo "4. (Optional) Wire \`.github/workflows/deploy.yml\` to this project for CI deploys."
    echo "5. (Optional) SMS alert channel: Console → create 'Coordinator SMS', then"
    echo "   \`enable_sms_alerts = true\` in ${TFVARS_NAME} and re-apply."
    echo ""
    echo "## Verification results"
    echo ""
    if [[ ${#VERIFY_RESULTS[@]} -gt 0 ]]; then
      for r in "${VERIFY_RESULTS[@]}"; do
        echo "- ${r}"
      done
    else
      echo "- (no Phase 8 results — Phase 8 may have been skipped via --start-phase)"
    fi
    echo ""
    echo "## Per-phase elapsed times (measured RTO)"
    echo ""
    echo "Note: Phase 6 timings include operator review time on the main \`terraform apply\` unless run with \`--yes\`. Use \`--yes\` for a comparable RTO measurement across runs."
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

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
      echo "ERROR: Application Default Credentials are not valid." >&2
      echo "Fix by running:" >&2
      echo "  gcloud auth application-default login" >&2
      echo "Then re-run this script." >&2
      exit 1
    fi
  fi

  # Firebase CLI tokens expire faster than ADC (~1h idle) and are not
  # covered by the ADC preflight above — caught mid-run (Phase 7
  # firebase deploy) on the dev-03 live drill instead of at the start.
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! firebase projects:list >/dev/null 2>&1; then
      echo "ERROR: Firebase CLI credentials are not valid." >&2
      echo "Fix by running:" >&2
      echo "  firebase login --reauth" >&2
      echo "Then re-run this script." >&2
      exit 1
    fi
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
  # Phase 9 (manifest write) MUST run whenever Phase 8 was entered, even
  # if one or more of its checks failed — an environment built but
  # missing its manifest is worse than one whose manifest records which
  # checks to verify manually. The fail-8 decision is therefore deferred
  # until after phase9 completes, not made from inside phase8.
  [[ "${START_PHASE}" -le 9 ]] && phase9

  if [[ "${OVERALL_VERIFY_OK}" -ne 1 ]]; then
    fail 8 "one or more verification checks failed — see manifest and results above."
  fi

  banner "DONE"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry run complete — no gcloud/terraform/firebase calls were made."
  else
    log "Environment build complete. See ${OUTPUT_FILE} for the full manifest."
  fi
}

main
