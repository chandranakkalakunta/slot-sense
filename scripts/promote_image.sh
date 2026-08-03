#!/usr/bin/env bash
# Copy a backend image from a source Artifact Registry to the target env's AR.
# Same tag on both sides (short git SHA). Fail closed if source is missing —
# never rebuild here (ADR-0045 same-artifact promote; docs/design/same-sha-image-promote.md).
#
# Required env:
#   SLOTSENSE_PROJECT              destination GCP project
#   SLOTSENSE_REGION               region for both ARs (same region today)
#   SLOTSENSE_ARTIFACT_REPO        destination AR repo id
#   SLOTSENSE_SOURCE_PROJECT       source GCP project (e.g. sport-slot-dev)
#   SLOTSENSE_SOURCE_ARTIFACT_REPO source AR repo id
#
# Usage:
#   ./scripts/promote_image.sh <git-sha-or-short-tag>
# Writes the short tag to .last_image_tag for deploy_cloud_run.sh.
set -euo pipefail

: "${SLOTSENSE_PROJECT:?ERROR: SLOTSENSE_PROJECT must be set.}"
: "${SLOTSENSE_REGION:?ERROR: SLOTSENSE_REGION must be set.}"
: "${SLOTSENSE_ARTIFACT_REPO:?ERROR: SLOTSENSE_ARTIFACT_REPO must be set.}"
: "${SLOTSENSE_SOURCE_PROJECT:?ERROR: SLOTSENSE_SOURCE_PROJECT must be set.}"
: "${SLOTSENSE_SOURCE_ARTIFACT_REPO:?ERROR: SLOTSENSE_SOURCE_ARTIFACT_REPO must be set.}"

PROJECT="${SLOTSENSE_PROJECT}"
REGION="${SLOTSENSE_REGION}"
DEST_REPO="${SLOTSENSE_ARTIFACT_REPO}"
SRC_PROJECT="${SLOTSENSE_SOURCE_PROJECT}"
SRC_REPO="${SLOTSENSE_SOURCE_ARTIFACT_REPO}"
SERVICE="sport-slot-api"

cd "$(dirname "$0")/.."

RAW_TAG="${1:-}"
if [[ -z "${RAW_TAG}" ]]; then
  echo "ERROR: usage: $0 <git-sha-or-short-tag>" >&2
  exit 1
fi

# Prefer short SHA matching build_push.sh (git rev-parse --short).
if [[ "${#RAW_TAG}" -ge 7 ]]; then
  if git cat-file -e "${RAW_TAG}^{commit}" 2>/dev/null; then
    TAG="$(git rev-parse --short "${RAW_TAG}")"
  else
    TAG="${RAW_TAG:0:7}"
  fi
else
  TAG="${RAW_TAG}"
fi

SRC_IMAGE="${REGION}-docker.pkg.dev/${SRC_PROJECT}/${SRC_REPO}/${SERVICE}:${TAG}"
DEST_IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${DEST_REPO}/${SERVICE}:${TAG}"

echo "Promote (copy, no rebuild):"
echo "  source: ${SRC_IMAGE}"
echo "  dest:   ${DEST_IMAGE}"

if ! gcloud artifacts docker images describe "${SRC_IMAGE}" --project="${SRC_PROJECT}" >/dev/null 2>&1; then
  echo "ERROR: source image not found: ${SRC_IMAGE}" >&2
  echo "  Deploy git SHA ${TAG} to ${SRC_PROJECT} first (build path), then re-run promote." >&2
  echo "  Refusing to rebuild on the promote path (same-SHA image promote)." >&2
  exit 1
fi

# Cross-project copy. Caller must have AR reader on source + writer on dest
# (see docs/design/same-sha-image-promote.md IAM section).
gcloud artifacts docker images copy "${SRC_IMAGE}" "${DEST_IMAGE}" \
  --quiet

echo "Copied: ${DEST_IMAGE}"
echo "${TAG}" > .last_image_tag
echo "(tag recorded in .last_image_tag for deploy script)"
