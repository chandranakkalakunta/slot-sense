#!/usr/bin/env bash
# Deploy Cloud Run for any SlotSense environment. Coordinator-run. Guarded.
# Requires explicit target project — no silent sport-slot-dev default
# (same safety posture as scripts/build_push.sh after PR-I).
set -euo pipefail

: "${SLOTSENSE_PROJECT:?ERROR: SLOTSENSE_PROJECT must be set (no default — refusing to guess).}"
: "${SLOTSENSE_REGION:?ERROR: SLOTSENSE_REGION must be set.}"
: "${SLOTSENSE_ARTIFACT_REPO:?ERROR: SLOTSENSE_ARTIFACT_REPO must be set.}"

PROJECT="${SLOTSENSE_PROJECT}"
REGION="${SLOTSENSE_REGION}"
SERVICE="sport-slot-api"
SA="sa-cloud-run@${PROJECT}.iam.gserviceaccount.com"
TASKS_INVOKER_SA="sa-tasks-invoker@${PROJECT}.iam.gserviceaccount.com"
SCHEDULER_INVOKER_SA="sa-scheduler-invoker@${PROJECT}.iam.gserviceaccount.com"
TASKS_QUEUE="notifications"
ARTIFACT_REPO="${SLOTSENSE_ARTIFACT_REPO}"
IMAGE_BASE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/${SERVICE}"
BASE_DOMAIN="${SLOTSENSE_BASE_DOMAIN:-slotsense.chandraailabs.com}"
ADMIN_HOST="${SLOTSENSE_ADMIN_HOST:-admin.${BASE_DOMAIN}}"
# Logical env label for app config (not the GCP project id). CI/bootstrap
# should pass this; default keeps prior behaviour for sport-slot-dev deploys.
APP_ENVIRONMENT="${SLOTSENSE_APP_ENVIRONMENT:-development}"
INVOICE_BUCKET="${SLOTSENSE_INVOICE_EXPORT_BUCKET:-${PROJECT}-invoices}"

cd "$(dirname "$0")/.."

TAG="${1:-$(cat .last_image_tag 2>/dev/null || true)}"
if [[ -z "$TAG" ]]; then
  echo "ERROR: no tag given and no .last_image_tag — run build_push.sh first" >&2
  exit 1
fi
IMAGE="${IMAGE_BASE}:${TAG}"

REDIS_INFO=$(gcloud redis instances describe sport-slot-redis \
  --region="$REGION" --project="$PROJECT" --format="value(host,port)") || {
  echo "ERROR: could not describe Redis instance sport-slot-redis in $REGION." >&2
  echo "  (Check the instance exists AND the caller has roles/redis.viewer.)" >&2
  exit 1
}
REDIS_HOST=$(echo "$REDIS_INFO" | cut -f1)
REDIS_PORT=$(echo "$REDIS_INFO" | cut -f2)
if [[ -z "$REDIS_HOST" ]]; then
  echo "ERROR: Redis instance returned empty host — run setup_redis_infra.sh first" >&2
  exit 1
fi

# SPORTSLOT_WORKER_BASE_URL is the worker's own Cloud Tasks OIDC
# audience (auth/tasks_auth.py), so it must come from the service's
# EXISTING URL, not the revision about to be deployed. Cloud Run
# service URLs are stable across revisions, so reading it before this
# deploy is safe. This requires the service to already exist — true
# for every deploy after the first.
WORKER_URL=$(gcloud run services describe "$SERVICE" --project="$PROJECT" \
  --region="$REGION" --format="value(status.url)") || {
  echo "ERROR: could not describe existing service ${SERVICE} for SPORTSLOT_WORKER_BASE_URL." >&2
  echo "  (First-ever deploy? Deploy once without the worker URL, then redeploy.)" >&2
  exit 1
}
if [[ -z "$WORKER_URL" ]]; then
  echo "ERROR: service ${SERVICE} returned an empty URL." >&2
  exit 1
fi

echo "About to deploy ${IMAGE}"
echo "  service=${SERVICE} region=${REGION} project=${PROJECT} sa=${SA}"
echo "  mem=512Mi cpu=1 (ADR-0005)"
# Skip interactive confirmation in CI (CI=true is set by GitHub Actions).
if [ -z "${CI:-}" ]; then
  read -r -p "Type DEPLOY to proceed: " CONFIRM
  [[ "$CONFIRM" == "DEPLOY" ]] || { echo "Aborted."; exit 1; }
fi

# Scaling (min/max instances) is Terraform-owned per ADR-0041 D15
# and the D7 model — CI sets image + env only. Previously this
# script forced --max-instances=2, silently reverting Terraform's
# 10 on every deploy (found in DR drill Pass 1).
#
# Multi-env completeness: vertex_project / invoice bucket / welcome URLs
# previously fell through to config.py defaults of sport-slot-dev — wrong
# for any other project. Always pin them to the deploy target.
#
# BUILD_ID = git SHA (CI) or short tag; DEPLOYED_AT = UTC deploy timestamp
# for /health and /version (operators confirm which build is live).
DEPLOYED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
BUILD_ID_VALUE="${BUILD_ID:-unknown}"
echo "Deploy metadata: BUILD_ID=${BUILD_ID_VALUE} DEPLOYED_AT=${DEPLOYED_AT}"

gcloud run deploy "$SERVICE" \
  --project="$PROJECT" --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$SA" \
  --allow-unauthenticated \
  --ingress=internal-and-cloud-load-balancing \
  --memory=512Mi --cpu=1 \
  --set-env-vars="SPORTSLOT_ENVIRONMENT=${APP_ENVIRONMENT},SPORTSLOT_GCP_PROJECT=${PROJECT},SPORTSLOT_BASE_DOMAIN=${BASE_DOMAIN},SPORTSLOT_ADMIN_HOST=${ADMIN_HOST},SPORTSLOT_REDIS_HOST=${REDIS_HOST},SPORTSLOT_REDIS_PORT=${REDIS_PORT},SPORTSLOT_TASKS_QUEUE=${TASKS_QUEUE},SPORTSLOT_TASKS_LOCATION=${REGION},SPORTSLOT_WORKER_BASE_URL=${WORKER_URL},SPORTSLOT_TASKS_INVOKER_SA=${TASKS_INVOKER_SA},SPORTSLOT_SCHEDULER_INVOKER_SA=${SCHEDULER_INVOKER_SA},SPORTSLOT_CLOUD_RUN_SA_EMAIL=${SA},SPORTSLOT_VERTEX_PROJECT=${PROJECT},SPORTSLOT_INVOICE_EXPORT_BUCKET=${INVOICE_BUCKET},SPORTSLOT_WELCOME_LOGIN_URL=https://${BASE_DOMAIN}/signin,SPORTSLOT_RESET_CONTINUE_URL=https://${BASE_DOMAIN}/reset,BUILD_ID=${BUILD_ID_VALUE},DEPLOYED_AT=${DEPLOYED_AT}" \
  --network=default --subnet=default \
  --vpc-egress=private-ranges-only \
  --set-secrets="SPORTSLOT_REDIS_AUTH=redis-auth:latest,SPORTSLOT_RESEND_API_KEY=resend-api-key:latest"

URL=$(gcloud run services describe "$SERVICE" --project="$PROJECT" \
  --region="$REGION" --format="value(status.url)")
echo "Deployed. Service URL: ${URL}"
