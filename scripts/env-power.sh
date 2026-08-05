#!/usr/bin/env bash
#
# env-power.sh — FinOps sleep/wake for SlotSense GCP environments (ADR-0047)
#
# Manual:
#   scripts/env-power.sh status  --env test-03
#   scripts/env-power.sh disable --env test-03
#   scripts/env-power.sh enable  --env test-03
#   scripts/env-power.sh hold    --env test-03 --days 1 --reason "soak"
#   scripts/env-power.sh release-hold --env test-03
#   scripts/env-power.sh list
#
# Automation (nightly GHA):
#   scripts/env-power.sh disable --env test-03 --yes --reason nightly
#
# Disable (near-zero runtime cost):
#   - Delete Memorystore Redis (primary fixed cost)
#   - Cloud Run min instances → 0
#   - Pause Cloud Scheduler jobs
#   - Soft-pause edge uptime check (path → /health-disabled-by-env-power)
# Keep: LB, DNS, certs, Firestore, Auth, AR, secrets metadata.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG_FILE="${REPO_ROOT}/infrastructure/env-power.json"

# ── CLI defaults ──────────────────────────────────────────────────────────
CMD=""
ENV_NAME=""
YES=0
DRY_RUN=0
REASON=""
HOLD_UNTIL=""
HOLD_DAYS=""
LIST_ONLY=0

usage() {
  cat <<'EOF'
env-power.sh — FinOps environment power control (ADR-0047)

Usage:
  scripts/env-power.sh <command> [options]

Commands:
  status          Show ENABLED/DISABLED, redis, min instances, hold
  disable         Sleep env (delete Redis, min=0, pause scheduler/uptime)
  enable          Wake env (recreate Redis, patch Cloud Run, resume)
  hold            Skip nightly disable until --until or --days
  release-hold    Clear hold
  list            All registry envs + quick power status

Options:
  --env NAME      Registry key (dev | dev-03 | test-01 | test-03 | …)
  --yes, -y       Non-interactive (required for CI)
  --reason TEXT   Reason for disable/hold (logged in state)
  --until ISO     Hold until timestamp (e.g. 2026-08-06T23:59:59+05:30)
  --days N        Hold for N days from now (Asia/Kolkata calendar-ish)
  --dry-run       Print actions only
  -h, --help      This help

Examples:
  scripts/env-power.sh status --env test-03
  scripts/env-power.sh disable --env test-03 --yes --reason "done for the day"
  scripts/env-power.sh hold --env test-03 --days 1 --reason "soak"
  scripts/env-power.sh enable --env test-03 --yes
EOF
}

fail() { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[env-power] $*"; }
run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

# ── Parse args ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    status|disable|enable|hold|release-hold|list)
      CMD="$1"; shift ;;
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --until) HOLD_UNTIL="${2:-}"; shift 2 ;;
    --days) HOLD_DAYS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "${CMD}" ]] || { usage; exit 1; }
need_cmd gcloud
need_cmd jq
need_cmd python3
[[ -f "${REG_FILE}" ]] || fail "missing registry ${REG_FILE}"

if [[ "${CMD}" == "list" ]]; then
  LIST_ONLY=1
fi

# ── Registry load ─────────────────────────────────────────────────────────
load_env() {
  local name="$1"
  local row
  row="$(jq -c --arg e "${name}" '.environments[$e] // empty' "${REG_FILE}")"
  [[ -n "${row}" && "${row}" != "null" ]] || fail "unknown env '${name}'. Known: $(jq -r '.environments|keys|join(", ")' "${REG_FILE}")"

  EP_PROJECT="$(echo "${row}" | jq -r .project_id)"
  EP_NIGHTLY="$(echo "${row}" | jq -r '.nightly_disable // true')"
  EP_BASE_DOMAIN="$(echo "${row}" | jq -r '.base_domain // empty')"
  EP_HEALTH_URL="$(echo "${row}" | jq -r '.health_url // empty')"
  EP_MIN="$(echo "${row}" | jq -r '.on_min_instances // empty')"
  if [[ -z "${EP_MIN}" || "${EP_MIN}" == "null" ]]; then
    EP_MIN="$(jq -r .defaults.on_min_instances "${REG_FILE}")"
  fi
  EP_REGION="$(jq -r .defaults.region "${REG_FILE}")"
  EP_REDIS="$(jq -r .defaults.redis_instance "${REG_FILE}")"
  EP_SERVICE="$(jq -r .defaults.cloud_run_service "${REG_FILE}")"
  EP_SECRET="$(jq -r .defaults.redis_secret "${REG_FILE}")"
  local suffix
  suffix="$(jq -r .defaults.power_bucket_suffix "${REG_FILE}")"
  EP_BUCKET="${EP_PROJECT}-${suffix}"
}

# ── GCS state / hold ──────────────────────────────────────────────────────
ensure_bucket() {
  if gcloud storage buckets describe "gs://${EP_BUCKET}" --project="${EP_PROJECT}" >/dev/null 2>&1; then
    return 0
  fi
  log "creating state bucket gs://${EP_BUCKET}"
  run gcloud storage buckets create "gs://${EP_BUCKET}" \
    --project="${EP_PROJECT}" \
    --location="${EP_REGION}" \
    --uniform-bucket-level-access
}

gcs_cat() {
  local path="$1"
  gcloud storage cat "gs://${EP_BUCKET}/${path}" --project="${EP_PROJECT}" 2>/dev/null || true
}

gcs_write() {
  local path="$1"
  local body="$2"
  ensure_bucket
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: write gs://${EP_BUCKET}/${path}"
    return 0
  fi
  printf '%s' "${body}" | gcloud storage cp - "gs://${EP_BUCKET}/${path}" --project="${EP_PROJECT}"
}

gcs_rm() {
  local path="$1"
  if gcloud storage ls "gs://${EP_BUCKET}/${path}" --project="${EP_PROJECT}" >/dev/null 2>&1; then
    run gcloud storage rm "gs://${EP_BUCKET}/${path}" --project="${EP_PROJECT}"
  fi
}

write_state() {
  local status="$1"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local actor
  actor="${GITHUB_ACTOR:-${USER:-unknown}}"
  local json
  json="$(jq -nc \
    --arg status "${status}" \
    --arg at "${now}" \
    --arg by "${actor}" \
    --arg reason "${REASON:-}" \
    --arg env "${ENV_NAME}" \
    --arg project "${EP_PROJECT}" \
    '{status:$status, env:$env, project_id:$project, updated_at:$at, updated_by:$by, reason:$reason}')"
  gcs_write "state.json" "${json}"
}

read_state_status() {
  local raw
  raw="$(gcs_cat state.json)"
  if [[ -z "${raw}" ]]; then
    echo "UNKNOWN"
    return
  fi
  echo "${raw}" | jq -r '.status // "UNKNOWN"'
}

hold_active() {
  local raw until_ts
  raw="$(gcs_cat hold.json)"
  [[ -n "${raw}" ]] || return 1
  until_ts="$(echo "${raw}" | jq -r '.until // empty')"
  [[ -n "${until_ts}" ]] || return 1
  python3 - "${until_ts}" <<'PY'
import sys
from datetime import datetime, timezone
raw = sys.argv[1]
# support Z and offsets
s = raw.replace("Z", "+00:00")
try:
    until = datetime.fromisoformat(s)
except ValueError:
    sys.exit(1)
if until.tzinfo is None:
    until = until.replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
sys.exit(0 if now < until else 1)
PY
}

# ── Resource helpers ──────────────────────────────────────────────────────
redis_exists() {
  gcloud redis instances describe "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" >/dev/null 2>&1
}

redis_host_port() {
  gcloud redis instances describe "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" \
    --format="value(host,port)"
}

cloud_run_min() {
  gcloud run services describe "${EP_SERVICE}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" \
    --format='value(spec.template.metadata.annotations["autoscaling.knative.dev/minScale"])' \
    2>/dev/null || echo "?"
}

pause_schedulers() {
  local jobs
  jobs="$(gcloud scheduler jobs list --location="${EP_REGION}" --project="${EP_PROJECT}" \
    --format='value(name)' 2>/dev/null || true)"
  if [[ -z "${jobs}" ]]; then
    log "no Cloud Scheduler jobs"
    return 0
  fi
  while IFS= read -r job; do
    [[ -z "${job}" ]] && continue
    local short
    short="$(basename "${job}")"
    log "pause scheduler ${short}"
    run gcloud scheduler jobs pause "${short}" \
      --location="${EP_REGION}" --project="${EP_PROJECT}" || true
  done <<< "${jobs}"
}

resume_schedulers() {
  local jobs
  jobs="$(gcloud scheduler jobs list --location="${EP_REGION}" --project="${EP_PROJECT}" \
    --format='value(name)' 2>/dev/null || true)"
  if [[ -z "${jobs}" ]]; then
    return 0
  fi
  while IFS= read -r job; do
    [[ -z "${job}" ]] && continue
    local short
    short="$(basename "${job}")"
    log "resume scheduler ${short}"
    run gcloud scheduler jobs resume "${short}" \
      --location="${EP_REGION}" --project="${EP_PROJECT}" || true
  done <<< "${jobs}"
}

# Soft-pause uptime via Monitoring API: switch HTTP path away from /health
# so probes do not wake the app / page on real failures. Restored on enable.
# Uses REST (not `gcloud … update`) for a stable, least-surprise path.
UPTIME_DISABLED_PATH="/health-disabled-by-env-power"

_monitoring_access_token() {
  gcloud auth print-access-token 2>/dev/null || true
}

_uptime_check_ids() {
  gcloud monitoring uptime list-configs --project="${EP_PROJECT}" \
    --format='value(name)' 2>/dev/null || true
}

_patch_uptime_path() {
  local check_id="$1"
  local new_path="$2"
  local token
  token="$(_monitoring_access_token)"
  [[ -n "${token}" ]] || { log "WARN: no access token for uptime patch"; return 0; }
  # check_id is projects/.../uptimeCheckConfigs/ID
  local url="https://monitoring.googleapis.com/v3/${check_id}?updateMask=httpCheck.path"
  local body
  body="$(jq -nc --arg p "${new_path}" '{httpCheck:{path:$p}}')"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: PATCH uptime ${check_id} path=${new_path}"
    return 0
  fi
  local code
  code="$(curl -sS -o /tmp/env-power-uptime.json -w '%{http_code}' -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${body}" \
    "${url}" || echo 000)"
  if [[ "${code}" != "200" ]]; then
    log "WARN: uptime path patch HTTP ${code} for ${check_id} (continuing)"
  else
    log "uptime ${check_id} path → ${new_path}"
  fi
}

soft_pause_uptime() {
  local ids id
  ids="$(_uptime_check_ids)"
  [[ -n "${ids}" ]] || { log "no uptime checks"; return 0; }
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    _patch_uptime_path "${id}" "${UPTIME_DISABLED_PATH}"
  done <<< "${ids}"
}

soft_resume_uptime() {
  local ids id
  ids="$(_uptime_check_ids)"
  [[ -n "${ids}" ]] || return 0
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    _patch_uptime_path "${id}" "/health"
  done <<< "${ids}"
}

set_run_min() {
  local min="$1"
  log "Cloud Run ${EP_SERVICE} min-instances=${min}"
  run gcloud run services update "${EP_SERVICE}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" \
    --min-instances="${min}" \
    --quiet
}

patch_run_redis_env() {
  local host="$1"
  local port="$2"
  log "patch Cloud Run Redis env host=${host} port=${port}"
  run gcloud run services update "${EP_SERVICE}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" \
    --update-env-vars="SPORTSLOT_REDIS_HOST=${host},SPORTSLOT_REDIS_PORT=${port}" \
    --quiet
}

delete_redis() {
  if ! redis_exists; then
    log "Redis ${EP_REDIS} already absent"
    return 0
  fi
  log "deleting Redis ${EP_REDIS} (primary cost off) — may take several minutes"
  run gcloud redis instances delete "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" --quiet
  # wait until gone
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local i
  for i in $(seq 1 60); do
    if ! redis_exists; then
      log "Redis deleted"
      return 0
    fi
    sleep 10
  done
  fail "Redis still present after wait"
}

create_redis_and_secret() {
  if redis_exists; then
    log "Redis ${EP_REDIS} already exists"
  else
    log "creating Redis ${EP_REDIS} Basic 1GB (READY often 10–20 min)"
    run gcloud redis instances create "${EP_REDIS}" \
      --project="${EP_PROJECT}" --region="${EP_REGION}" \
      --tier=basic --size=1 --redis-version=redis_7_0 \
      --network=default --enable-auth \
      --quiet
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local i state
  for i in $(seq 1 90); do
    state="$(gcloud redis instances describe "${EP_REDIS}" \
      --region="${EP_REGION}" --project="${EP_PROJECT}" \
      --format='value(state)' 2>/dev/null || echo UNKNOWN)"
    log "Redis state=${state} (${i})"
    [[ "${state}" == "READY" ]] && break
    sleep 15
  done
  state="$(gcloud redis instances describe "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" \
    --format='value(state)')"
  [[ "${state}" == "READY" ]] || fail "Redis not READY (state=${state})"

  local host port auth
  host="$(gcloud redis instances describe "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" --format='value(host)')"
  port="$(gcloud redis instances describe "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" --format='value(port)')"
  auth="$(gcloud redis instances get-auth-string "${EP_REDIS}" \
    --region="${EP_REGION}" --project="${EP_PROJECT}" --format='value(authString)')"

  if ! gcloud secrets describe "${EP_SECRET}" --project="${EP_PROJECT}" >/dev/null 2>&1; then
    run gcloud secrets create "${EP_SECRET}" --project="${EP_PROJECT}" \
      --replication-policy="user-managed" --locations="${EP_REGION}"
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: add secret version ${EP_SECRET}"
  else
    printf '%s' "${auth}" | gcloud secrets versions add "${EP_SECRET}" \
      --project="${EP_PROJECT}" --data-file=-
  fi
  log "redis-auth secret version updated"

  local sa="sa-cloud-run@${EP_PROJECT}.iam.gserviceaccount.com"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: secretAccessor for ${sa}"
  else
    gcloud secrets add-iam-policy-binding "${EP_SECRET}" --project="${EP_PROJECT}" \
      --member="serviceAccount:${sa}" \
      --role="roles/secretmanager.secretAccessor" >/dev/null || true
  fi

  patch_run_redis_env "${host}" "${port}"
}

smoke_health() {
  local url="${EP_HEALTH_URL}"
  if [[ -z "${url}" ]]; then
    log "no health_url in registry — skip smoke"
    return 0
  fi
  log "smoke GET ${url}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${url}" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    log "health OK (${code})"
  else
    log "WARN: health returned ${code} (cold start or LB — re-check shortly)"
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────
cmd_status() {
  load_env "${ENV_NAME}"
  local st redis_st min hold_raw hold_line
  st="$(read_state_status 2>/dev/null || echo UNKNOWN)"
  if redis_exists; then
    redis_st="PRESENT $(redis_host_port | tr '\t' ':')"
  else
    redis_st="ABSENT"
  fi
  min="$(cloud_run_min)"
  hold_line="none"
  if hold_active; then
    hold_raw="$(gcs_cat hold.json)"
    hold_line="$(echo "${hold_raw}" | jq -c '{until,reason,set_by}')"
  else
    hold_raw="$(gcs_cat hold.json)"
    if [[ -n "${hold_raw}" ]]; then
      hold_line="expired $(echo "${hold_raw}" | jq -c '{until,reason}')"
    fi
  fi
  cat <<EOF
env:              ${ENV_NAME}
project:          ${EP_PROJECT}
region:           ${EP_REGION}
power_state:      ${st}
nightly_disable:  ${EP_NIGHTLY}
redis:            ${redis_st}
cloud_run_min:    ${min:-?}
hold:             ${hold_line}
health_url:       ${EP_HEALTH_URL:-n/a}
state_bucket:     gs://${EP_BUCKET}
residual_note:    LB/static IP + storage remain while DISABLED (ADR-0047 D1)
EOF
}

cmd_disable() {
  load_env "${ENV_NAME}"
  if [[ "${YES}" -ne 1 ]]; then
    echo "About to DISABLE env=${ENV_NAME} project=${EP_PROJECT}"
    echo "  - delete Redis ${EP_REDIS}"
    echo "  - Cloud Run min=0, pause schedulers, soft-pause uptime"
    read -r -p "Type DISABLE ${ENV_NAME} to proceed: " conf
    [[ "${conf}" == "DISABLE ${ENV_NAME}" ]] || fail "confirmation failed"
  fi

  if hold_active && [[ "${REASON}" == "nightly" ]]; then
    log "hold active — skip nightly disable for ${ENV_NAME}"
    gcs_cat hold.json | jq . || true
    exit 0
  fi

  log "disable start env=${ENV_NAME} project=${EP_PROJECT} reason=${REASON:-manual}"
  pause_schedulers
  soft_pause_uptime
  set_run_min 0
  delete_redis
  write_state "DISABLED"
  log "DISABLED ${ENV_NAME}. Residual cost: LB/IP/storage only."
  log "Wake with: scripts/env-power.sh enable --env ${ENV_NAME} --yes"
}

cmd_enable() {
  load_env "${ENV_NAME}"
  if [[ "${YES}" -ne 1 ]]; then
    echo "About to ENABLE env=${ENV_NAME} project=${EP_PROJECT}"
    echo "  Redis create may take 10–20 minutes."
    read -r -p "Type ENABLE ${ENV_NAME} to proceed: " conf
    [[ "${conf}" == "ENABLE ${ENV_NAME}" ]] || fail "confirmation failed"
  fi

  log "enable start env=${ENV_NAME} project=${EP_PROJECT}"
  create_redis_and_secret
  set_run_min "${EP_MIN}"
  resume_schedulers
  soft_resume_uptime
  smoke_health
  write_state "ENABLED"
  log "ENABLED ${ENV_NAME} (min_instances=${EP_MIN})"
}

cmd_hold() {
  load_env "${ENV_NAME}"
  local until_iso
  if [[ -n "${HOLD_UNTIL}" ]]; then
    until_iso="${HOLD_UNTIL}"
  elif [[ -n "${HOLD_DAYS}" ]]; then
    until_iso="$(python3 - "${HOLD_DAYS}" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
# IST = UTC+5:30
days = int(sys.argv[1])
ist = timezone(timedelta(hours=5, minutes=30))
now = datetime.now(ist)
# end of local day + (days-1) extra days at 23:59:59 IST
end = (now + timedelta(days=days)).replace(hour=23, minute=59, second=59, microsecond=0)
print(end.isoformat())
PY
)"
  else
    fail "hold requires --until ISO or --days N"
  fi
  [[ -n "${REASON}" ]] || REASON="hold"
  local now actor json
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  actor="${GITHUB_ACTOR:-${USER:-unknown}}"
  json="$(jq -nc \
    --arg until "${until_iso}" \
    --arg reason "${REASON}" \
    --arg by "${actor}" \
    --arg at "${now}" \
    --arg env "${ENV_NAME}" \
    '{until:$until, reason:$reason, set_by:$by, set_at:$at, env:$env}')"
  gcs_write "hold.json" "${json}"
  log "hold set until ${until_iso} reason=${REASON}"
  echo "${json}" | jq .
}

cmd_release_hold() {
  load_env "${ENV_NAME}"
  gcs_rm "hold.json"
  log "hold released for ${ENV_NAME}"
}

cmd_list() {
  local keys
  keys="$(jq -r '.environments|keys[]' "${REG_FILE}")"
  printf '%-10s %-24s %-8s %-10s %s\n' "ENV" "PROJECT" "NIGHTLY" "STATE" "REDIS"
  while IFS= read -r e; do
    ENV_NAME="${e}"
    load_env "${e}"
    local st redis_st
    st="$(read_state_status 2>/dev/null || echo "?")"
    if redis_exists 2>/dev/null; then redis_st="up"; else redis_st="down"; fi
    printf '%-10s %-24s %-8s %-10s %s\n' "${e}" "${EP_PROJECT}" "${EP_NIGHTLY}" "${st}" "${redis_st}"
  done <<< "${keys}"
}

# ── Dispatch ──────────────────────────────────────────────────────────────
if [[ "${LIST_ONLY}" -eq 1 ]]; then
  cmd_list
  exit 0
fi

[[ -n "${ENV_NAME}" ]] || fail "--env is required for ${CMD}"

case "${CMD}" in
  status) cmd_status ;;
  disable) cmd_disable ;;
  enable) cmd_enable ;;
  hold) cmd_hold ;;
  release-hold) cmd_release_hold ;;
  *) fail "unknown command ${CMD}" ;;
esac
