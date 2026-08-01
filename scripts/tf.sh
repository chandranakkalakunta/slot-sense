#!/usr/bin/env bash
#
# tf.sh — environment-safe Terraform wrapper
#
# Terraform selects its STATE (backend, via `-backend-config`, cached in
# .terraform/) and its VARIABLES (via `-var-file`) through two independent
# mechanisms — a Terraform backend block cannot itself take variables, so
# there is no Terraform-native way to bind the two together. Left alone
# they can silently disagree: a stale `.terraform/` from a previous `init`
# points state at one project while a plain `-var-file` points variables
# at another. (This is exactly what happened during the 2026-07 DR drill:
# backend still on the drill project, tfvars on dev — Terraform correctly
# planned to destroy 95 drill resources and recreate them as dev
# resources.)
#
# tf.sh makes environment selection ATOMIC: one argument (ENV) selects
# both the backend and the var-file, re-initializing the backend whenever
# it has drifted, and refusing to run anything if the live state's
# project_id doesn't match what the environment expects.
#
# Usage:
#   scripts/tf.sh <env> <terraform-command> [args...]
#   scripts/tf.sh --list
#   scripts/tf.sh --help
#
# Examples:
#   scripts/tf.sh dev plan
#   scripts/tf.sh dev-03 apply -target=google_project_service.enabled_apis
#   scripts/tf.sh dev import google_storage_bucket.foo my-bucket
#
# Adding an environment: add ONE case arm to env_lookup() below — no other
# file needs to change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
LOG_FILE="${TF_DIR}/.tf.sh.log"

# ── Environment registry ────────────────────────────────────────────────
# ONE structure. To add an environment: add one case arm here, setting
# ENV_PROJECT_ID / ENV_BUCKET / ENV_PREFIX / ENV_VARFILE. Nothing else in
# this script needs to change. Keep ENV_NAMES in sync — it drives --list
# and unknown-env error messages.
ENV_NAMES="dev dev-03 test-01"

env_lookup() {
  case "$1" in
    dev)
      ENV_PROJECT_ID="sport-slot-dev"
      ENV_BUCKET="sport-slot-dev-tfstate"
      ENV_PREFIX="terraform/state"
      ENV_VARFILE="terraform.tfvars"
      ;;
    dev-03)
      ENV_PROJECT_ID="slot-sense-dev-03"
      ENV_BUCKET="slot-sense-dev-03-tfstate"
      ENV_PREFIX="terraform/state"
      ENV_VARFILE="slot-sense-dev-03.tfvars"
      ;;
    test-01)
      ENV_PROJECT_ID="slot-sense-test-01"
      ENV_BUCKET="slot-sense-test-01-tfstate"
      ENV_PREFIX="terraform/state"
      ENV_VARFILE="slot-sense-test-01.tfvars"
      ;;
    *)
      return 1
      ;;
  esac
}

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() {
  local line
  line="[$(timestamp)] $*"
  echo "${line}"
  echo "${line}" >> "${LOG_FILE}"
}

fail() {
  log "FATAL: $*"
  exit 1
}

usage() {
  cat <<'EOF'
tf.sh — environment-safe Terraform wrapper

Usage:
  scripts/tf.sh <env> <terraform-command> [args...]
  scripts/tf.sh --list
  scripts/tf.sh --help

Examples:
  scripts/tf.sh dev plan
  scripts/tf.sh dev-03 apply -target=google_project_service.enabled_apis
  scripts/tf.sh dev import google_storage_bucket.foo my-bucket

No environment has a default — every invocation must name one explicitly.
Run 'scripts/tf.sh --list' to see registered environments.
EOF
}

list_envs() {
  echo "Registered environments:"
  printf '  %-10s %-24s %-28s %s\n' "ENV" "PROJECT_ID" "BUCKET" "VARFILE"
  for e in ${ENV_NAMES}; do
    env_lookup "${e}"
    printf '  %-10s %-24s %-28s %s\n' "${e}" "${ENV_PROJECT_ID}" "${ENV_BUCKET}" "${ENV_VARFILE}"
  done
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "required binary '$1' not found on PATH."
}

# ── Argument parsing ─────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    list_envs
    exit 0
    ;;
esac

ENV="$1"
shift

if [[ $# -eq 0 ]]; then
  fail "no terraform command given. Usage: scripts/tf.sh <env> <terraform-command> [args...]"
fi

TF_CMD="$1"
shift
TF_ARGS=("$@")

if ! env_lookup "${ENV}"; then
  {
    echo "FATAL: unknown environment '${ENV}'."
    echo ""
    list_envs
  } >&2
  exit 1
fi

for a in "${TF_ARGS[@]+"${TF_ARGS[@]}"}"; do
  case "${a}" in
    -var-file=*|-var-file)
      fail "do not pass -var-file manually — tf.sh injects it automatically from the environment registry ('${ENV}' -> ${ENV_VARFILE})."
      ;;
  esac
done

require_bin terraform
require_bin jq

VARFILE_PATH="${TF_DIR}/${ENV_VARFILE}"
[[ -f "${VARFILE_PATH}" ]] || fail "var-file '${ENV_VARFILE}' not found at ${VARFILE_PATH} for env '${ENV}'."

log "tf.sh: env=${ENV} project=${ENV_PROJECT_ID} bucket=${ENV_BUCKET} varfile=${ENV_VARFILE} command='terraform ${TF_CMD} ${TF_ARGS[*]+${TF_ARGS[*]}}'"

cd "${TF_DIR}"

run_init() {
  log "Running: terraform init -reconfigure -backend-config=bucket=${ENV_BUCKET} -backend-config=prefix=${ENV_PREFIX} ${*+$*}"
  terraform init -reconfigure \
    -backend-config="bucket=${ENV_BUCKET}" \
    -backend-config="prefix=${ENV_PREFIX}" \
    "$@"
}

ensure_backend() {
  local pointer="${TF_DIR}/.terraform/terraform.tfstate"
  local current_bucket=""
  if [[ -f "${pointer}" ]]; then
    current_bucket="$(jq -r '.backend.config.bucket // empty' "${pointer}" 2>/dev/null || true)"
  fi
  if [[ "${current_bucket}" != "${ENV_BUCKET}" ]]; then
    log "Backend bucket mismatch (current='${current_bucket:-<uninitialized>}', expected='${ENV_BUCKET}') — reinitializing backend for '${ENV}'."
    run_init
  else
    log "Backend already initialized for bucket '${ENV_BUCKET}' — skipping re-init."
  fi
}

verify_live_project() {
  log "Verifying live state belongs to project '${ENV_PROJECT_ID}'..."
  local live_project=""
  if ! live_project="$(terraform output -raw project_id 2>/dev/null)"; then
    log "WARNING: could not read 'project_id' output from state (empty/new state?) — skipping live-project verification. Proceed with caution."
    return 0
  fi
  if [[ -z "${live_project}" ]]; then
    log "WARNING: 'project_id' output is empty — skipping live-project verification. Proceed with caution."
    return 0
  fi
  if [[ "${live_project}" != "${ENV_PROJECT_ID}" ]]; then
    fail "live state project_id ('${live_project}') does not match env '${ENV}' expected project_id ('${ENV_PROJECT_ID}'). Refusing to run 'terraform ${TF_CMD}' — this is exactly the backend/var-file mismatch tf.sh exists to prevent."
  fi
  log "Verified: live state belongs to '${ENV_PROJECT_ID}'."
}

if [[ "${TF_CMD}" == "init" ]]; then
  run_init "${TF_ARGS[@]+"${TF_ARGS[@]}"}"
  log "init complete for env '${ENV}'."
  exit 0
fi

ensure_backend
verify_live_project

case "${TF_CMD}" in
  plan|apply|destroy|refresh|import|console)
    log "Running: terraform ${TF_CMD} -var-file=${ENV_VARFILE} ${TF_ARGS[*]+${TF_ARGS[*]}}"
    terraform "${TF_CMD}" -var-file="${ENV_VARFILE}" "${TF_ARGS[@]+"${TF_ARGS[@]}"}"
    ;;
  *)
    log "Running: terraform ${TF_CMD} ${TF_ARGS[*]+${TF_ARGS[*]}}"
    terraform "${TF_CMD}" "${TF_ARGS[@]+"${TF_ARGS[@]}"}"
    ;;
esac

log "terraform ${TF_CMD} completed for env '${ENV}'."
