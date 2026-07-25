#!/usr/bin/env bash
# Build backend image via Cloud Build, push to Artifact Registry.
# Coordinator-run. Tag = short git SHA (clean tree required).
set -euo pipefail

: "${SLOTSENSE_PROJECT:?ERROR: SLOTSENSE_PROJECT must be set (no default — refusing to guess).}"
: "${SLOTSENSE_REGION:?ERROR: SLOTSENSE_REGION must be set.}"
: "${SLOTSENSE_ARTIFACT_REPO:?ERROR: SLOTSENSE_ARTIFACT_REPO must be set.}"
PROJECT="${SLOTSENSE_PROJECT}"
REGION="${SLOTSENSE_REGION}"
ARTIFACT_REPO="${SLOTSENSE_ARTIFACT_REPO}"
IMAGE_BASE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/sport-slot-api"
BUCKET="gs://${PROJECT}-cloudbuild"

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree not clean — commit first (image tag = git SHA)" >&2
  exit 1
fi
TAG=$(git rev-parse --short HEAD)
IMAGE="${IMAGE_BASE}:${TAG}"

echo "Building ${IMAGE} via Cloud Build (region ${REGION})"
gcloud builds submit backend \
  --project="$PROJECT" --region="$REGION" \
  --service-account="projects/${PROJECT}/serviceAccounts/sa-cloud-build@${PROJECT}.iam.gserviceaccount.com" \
  --config=backend/cloudbuild.yaml \
  --substitutions=_IMAGE="$IMAGE" \
  --gcs-source-staging-dir="${BUCKET}/source"

echo "Pushed: ${IMAGE}"
echo "$TAG" > .last_image_tag
echo "(tag recorded in .last_image_tag for deploy script)"
