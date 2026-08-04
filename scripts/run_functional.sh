#!/usr/bin/env bash
# Run S-FUNC live-environment suite (ADR-0045) against a deployed env.
#
# Usage:
#   ./scripts/run_functional.sh              # interactive prompts + defaults
#   ./scripts/run_functional.sh --yes        # non-interactive (env / .env.local only)
#   ./scripts/run_functional.sh -k spa       # pytest filter args after options
#
# Loads tests/functional/.env.local if present, then prompts for any missing
# required values (with defaults). Optional: writes answers back to .env.local
# when interactive.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FUNC_DIR="${REPO_ROOT}/tests/functional"
ENV_LOCAL="${FUNC_DIR}/.env.local"
ENV_EXAMPLE="${FUNC_DIR}/.env.example"
NON_INTERACTIVE=0
PYTEST_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      PYTEST_ARGS+=("$1")
      shift
      ;;
  esac
done

# ─── load existing .env.local ───────────────────────────────────────────
if [[ -f "${ENV_LOCAL}" ]]; then
  # shellcheck disable=SC1090
  set -a && source "${ENV_LOCAL}" && set +a
fi

# ─── helpers ────────────────────────────────────────────────────────────
_is_tty() { [[ -t 0 && -t 1 && "${NON_INTERACTIVE}" -eq 0 ]]; }

prompt_default() {
  # prompt_default VAR "Label" "default"
  local var="$1" label="$2" default="${3:-}"
  local cur="${!var:-}"
  local shown effective
  if [[ -n "${cur}" ]]; then
    effective="${cur}"
  else
    effective="${default}"
  fi
  if ! _is_tty; then
    printf -v "${var}" '%s' "${effective}"
    return 0
  fi
  if [[ -n "${default}" ]]; then
    shown=" [${default}]"
  else
    shown=""
  fi
  if [[ -n "${cur}" && "${cur}" != "${default}" ]]; then
    read -r -p "${label}${shown} (env: ${cur}): " input || true
  else
    read -r -p "${label}${shown}: " input || true
  fi
  if [[ -n "${input}" ]]; then
    printf -v "${var}" '%s' "${input}"
  else
    printf -v "${var}" '%s' "${effective}"
  fi
}

prompt_secret() {
  # prompt_secret VAR "Label"  — no default echo; empty keeps existing env
  local var="$1" label="$2"
  local cur="${!var:-}"
  if ! _is_tty; then
    return 0
  fi
  if [[ -n "${cur}" ]]; then
    read -r -s -p "${label} [set, Enter to keep]: " input || true
    echo
    if [[ -n "${input}" ]]; then
      printf -v "${var}" '%s' "${input}"
    fi
  else
    read -r -s -p "${label}: " input || true
    echo
    printf -v "${var}" '%s' "${input}"
  fi
}

prompt_yes_no() {
  local label="$1" default="${2:-y}"
  local yn
  if ! _is_tty; then
    [[ "${default}" == "y" ]]
    return $?
  fi
  read -r -p "${label} [y/n] (default ${default}): " yn || true
  yn="${yn:-$default}"
  [[ "${yn}" =~ ^[Yy] ]]
}

# ─── defaults ───────────────────────────────────────────────────────────
DEFAULT_BASE_DOMAIN="${FUNC_BASE_DOMAIN:-slotsense-test.chandraailabs.com}"
DEFAULT_PROJECT_ID="${FUNC_PROJECT_ID:-slot-sense-test-03}"
DEFAULT_TENANT_SLUG="${FUNC_TENANT_SLUG:-marina-skies}"

# ─── prompts ────────────────────────────────────────────────────────────
if _is_tty; then
  echo "=== S-FUNC live suite (ADR-0045) ==="
  echo "Press Enter to accept [defaults]. Ctrl-C to abort."
  echo
fi

prompt_default FUNC_BASE_DOMAIN "Base domain (ADR-0046)" "${DEFAULT_BASE_DOMAIN}"
prompt_default FUNC_ADMIN_HOST "Admin host" "admin.${FUNC_BASE_DOMAIN}"
prompt_default FUNC_TENANT_SLUG "Tenant slug" "${DEFAULT_TENANT_SLUG}"
prompt_default FUNC_PROJECT_ID "GCP / Firebase project id" "${DEFAULT_PROJECT_ID}"

# Firebase web API key — default from committed config if present
_FB_CFG="${REPO_ROOT}/infrastructure/firebase-web-configs/${FUNC_PROJECT_ID}.json"
_DEFAULT_API_KEY="${FUNC_FIREBASE_API_KEY:-}"
if [[ -z "${_DEFAULT_API_KEY}" && -f "${_FB_CFG}" ]]; then
  _DEFAULT_API_KEY="$(jq -r '.apiKey // empty' "${_FB_CFG}" 2>/dev/null || true)"
fi
prompt_default FUNC_FIREBASE_API_KEY "Firebase Web API key" "${_DEFAULT_API_KEY}"

prompt_default FUNC_RESIDENT_EMAIL "Resident (or tenant_admin) email" "${FUNC_RESIDENT_EMAIL:-}"
prompt_secret FUNC_RESIDENT_PASSWORD "Resident password"

prompt_default FUNC_FACILITY_ID "Facility id (empty = auto-pick first)" "${FUNC_FACILITY_ID:-}"
prompt_default FUNC_EXPECT_BUILD_ID "Expect build_id prefix (optional)" "${FUNC_EXPECT_BUILD_ID:-}"

if _is_tty; then
  if prompt_yes_no "Skip agent/Vertex test?" n; then
    FUNC_SKIP_AGENT=1
  else
    FUNC_SKIP_AGENT="${FUNC_SKIP_AGENT:-0}"
  fi
  if prompt_yes_no "Skip booking create (Redis path)?" n; then
    FUNC_SKIP_BOOKING=1
  else
    FUNC_SKIP_BOOKING="${FUNC_SKIP_BOOKING:-0}"
  fi
else
  FUNC_SKIP_AGENT="${FUNC_SKIP_AGENT:-0}"
  FUNC_SKIP_BOOKING="${FUNC_SKIP_BOOKING:-0}"
fi

# ─── validate required ──────────────────────────────────────────────────
_missing=0
for v in FUNC_BASE_DOMAIN FUNC_FIREBASE_API_KEY FUNC_RESIDENT_EMAIL FUNC_RESIDENT_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: ${v} is required." >&2
    _missing=1
  fi
done
if [[ "${_missing}" -eq 1 ]]; then
  echo "Hint: copy ${ENV_EXAMPLE} → ${ENV_LOCAL} or re-run interactively (TTY)." >&2
  exit 2
fi

# ─── optional save ──────────────────────────────────────────────────────
if _is_tty && prompt_yes_no "Save answers to tests/functional/.env.local?" y; then
  umask 077
  cat > "${ENV_LOCAL}" <<EOF
# Generated by scripts/run_functional.sh — do not commit
FUNC_BASE_DOMAIN=${FUNC_BASE_DOMAIN}
FUNC_ADMIN_HOST=${FUNC_ADMIN_HOST}
FUNC_TENANT_SLUG=${FUNC_TENANT_SLUG}
FUNC_PROJECT_ID=${FUNC_PROJECT_ID}
FUNC_FIREBASE_API_KEY=${FUNC_FIREBASE_API_KEY}
FUNC_RESIDENT_EMAIL=${FUNC_RESIDENT_EMAIL}
FUNC_RESIDENT_PASSWORD=${FUNC_RESIDENT_PASSWORD}
FUNC_FACILITY_ID=${FUNC_FACILITY_ID}
FUNC_EXPECT_BUILD_ID=${FUNC_EXPECT_BUILD_ID}
FUNC_SKIP_AGENT=${FUNC_SKIP_AGENT}
FUNC_SKIP_BOOKING=${FUNC_SKIP_BOOKING}
EOF
  echo "Wrote ${ENV_LOCAL}"
fi

export FUNC_BASE_DOMAIN FUNC_ADMIN_HOST FUNC_TENANT_SLUG FUNC_PROJECT_ID
export FUNC_FIREBASE_API_KEY FUNC_RESIDENT_EMAIL FUNC_RESIDENT_PASSWORD
export FUNC_FACILITY_ID FUNC_EXPECT_BUILD_ID FUNC_SKIP_AGENT FUNC_SKIP_BOOKING

echo
echo "S-FUNC target: base=${FUNC_BASE_DOMAIN} tenant=${FUNC_TENANT_SLUG} project=${FUNC_PROJECT_ID}"
echo "  admin=https://${FUNC_ADMIN_HOST}"
echo "  tenant=https://${FUNC_TENANT_SLUG}.${FUNC_BASE_DOMAIN}"
echo "  skip_agent=${FUNC_SKIP_AGENT} skip_booking=${FUNC_SKIP_BOOKING}"
echo

cd "${REPO_ROOT}/backend"
exec uv run pytest "${FUNC_DIR}" -m functional -v --tb=short "${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"}"
