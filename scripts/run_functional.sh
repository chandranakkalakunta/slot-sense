#!/usr/bin/env bash
# Run S-FUNC live-environment suite (ADR-0045) against a deployed env.
#
# Usage:
#   set -a && source tests/functional/.env.local && set +a
#   ./scripts/run_functional.sh
#   ./scripts/run_functional.sh -k spa   # filter
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FUNC_DIR="${REPO_ROOT}/tests/functional"

if [[ -z "${FUNC_BASE_DOMAIN:-}" ]]; then
  if [[ -f "${FUNC_DIR}/.env.local" ]]; then
    # shellcheck disable=SC1091
    set -a && source "${FUNC_DIR}/.env.local" && set +a
  fi
fi

if [[ -z "${FUNC_BASE_DOMAIN:-}" ]]; then
  echo "ERROR: FUNC_BASE_DOMAIN not set." >&2
  echo "  cp tests/functional/.env.example tests/functional/.env.local" >&2
  echo "  # edit credentials, then: source tests/functional/.env.local" >&2
  exit 2
fi

echo "S-FUNC target: base=${FUNC_BASE_DOMAIN} tenant=${FUNC_TENANT_SLUG:-?} project=${FUNC_PROJECT_ID:-?}"

cd "${REPO_ROOT}/backend"
exec uv run pytest "${FUNC_DIR}" -m functional -v --tb=short "$@"
