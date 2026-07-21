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
echo "  - Their Artifact Registry repositories (llm-app-*)"
echo "  - Their Cloud Storage buckets (llm-src-*)"
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
echo "--- Step 2: Deleting per-student Artifact Registry repositories ---"

if [ -n "$SERVICES" ]; then
  for SERVICE in $SERVICES; do
    echo "Deleting AR repository: $SERVICE"
    gcloud artifacts repositories delete "$SERVICE" \
      --location="$REGION" \
      --project="$PROJECT_ID" \
      --quiet 2>/dev/null || echo "  Skipped: $SERVICE (not found)"
  done
else
  echo "Nothing to delete."
fi

echo ""
echo "--- Step 3: Deleting per-student Cloud Storage buckets ---"

if [ -n "$SERVICES" ]; then
  for SERVICE in $SERVICES; do
    STUDENT_NAME="${SERVICE#llm-app-}"
    SRC_BUCKET="llm-src-${STUDENT_NAME}-${PROJECT_ID}"
    if gsutil ls "gs://${SRC_BUCKET}" &>/dev/null; then
      echo "Deleting bucket: gs://${SRC_BUCKET}"
      gsutil -m rm -r "gs://${SRC_BUCKET}" 2>/dev/null || echo "  Skipped: ${SRC_BUCKET}"
    else
      echo "  Bucket not found, skipping: gs://${SRC_BUCKET}"
    fi
  done
else
  echo "Nothing to delete."
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
