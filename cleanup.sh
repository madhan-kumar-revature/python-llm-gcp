#!/bin/bash
set -e

PROJECT_ID="project-cd9f1644-7a59-430b-ad4"
REGION="us-central1"
PROJECT_NUMBER="1037166449498"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

echo "========================================"
echo " GCP Cleanup Script"
echo " Project: $PROJECT_ID"
echo "========================================"
echo ""
echo "This will delete:"
echo "  - All Cloud Run services matching 'llm-app-*'"
echo "  - Their images from Artifact Registry"
echo "  - Source zips from Cloud Storage"
echo "  - IAM roles added to the Compute Engine SA"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "--- Step 1: Deleting Cloud Run services ---"

SERVICES=$(gcloud run services list \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="value(metadata.name)" \
  --filter="metadata.name~llm-app-" 2>/dev/null)

if [ -z "$SERVICES" ]; then
  echo "No llm-app-* services found."
else
  for SERVICE in $SERVICES; do
    echo "Deleting Cloud Run service: $SERVICE"
    gcloud run services delete "$SERVICE" \
      --project="$PROJECT_ID" \
      --region="$REGION" \
      --quiet
  done
fi

echo ""
echo "--- Step 2: Deleting images from Artifact Registry ---"

IMAGES=$(gcloud artifacts docker images list \
  "us-central1-docker.pkg.dev/$PROJECT_ID/cloud-run-source-deploy" \
  --project="$PROJECT_ID" \
  --filter="package~llm-app-" \
  --format="value(package)" 2>/dev/null | sort -u)

if [ -z "$IMAGES" ]; then
  echo "No llm-app-* images found in Artifact Registry."
else
  for IMAGE in $IMAGES; do
    echo "Deleting image: $IMAGE"
    gcloud artifacts docker images delete "$IMAGE" \
      --project="$PROJECT_ID" \
      --quiet \
      --delete-tags 2>/dev/null || echo "  Skipped (already gone or permission issue)"
  done
fi

echo ""
echo "--- Step 3: Deleting source zips from Cloud Storage ---"

BUCKET="run-sources-${PROJECT_ID}-${REGION}"
if gsutil ls "gs://$BUCKET/services/llm-app-*" &>/dev/null; then
  echo "Deleting source zips from gs://$BUCKET"
  gsutil -m rm -r "gs://$BUCKET/services/llm-app-*" 2>/dev/null || echo "  Skipped (already empty)"
else
  echo "No source zips found in gs://$BUCKET"
fi

echo ""
echo "--- Step 4: Removing IAM roles ---"

remove_binding() {
  local MEMBER=$1
  local ROLE=$2
  echo "Removing $ROLE from $MEMBER"
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$MEMBER" \
    --role="$ROLE" \
    --condition=None \
    --quiet 2>/dev/null || echo "  Skipped (binding not found)"
}

remove_binding "$COMPUTE_SA" "roles/storage.objectAdmin"
remove_binding "$COMPUTE_SA" "roles/artifactregistry.writer"
remove_binding "$COMPUTE_SA" "roles/logging.logWriter"

echo "Removing roles/artifactregistry.writer from $CLOUDBUILD_SA (repo level)"
gcloud artifacts repositories remove-iam-policy-binding cloud-run-source-deploy \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$CLOUDBUILD_SA" \
  --role="roles/artifactregistry.writer" \
  --quiet 2>/dev/null || echo "  Skipped (binding not found)"

echo ""
echo "========================================"
echo " Cleanup complete."
echo "========================================"
