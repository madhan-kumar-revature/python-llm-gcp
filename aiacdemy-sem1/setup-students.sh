#!/bin/bash
# setup-students.sh — run once by instructor before batch starts

PROJECT_ID="project-cd9f1644-7a59-430b-ad4"
REGION="us-central1"
PROJECT_NUMBER="1037166449498"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

while IFS= read -r STUDENT_EMAIL; do
  [ -z "$STUDENT_EMAIL" ] && continue

  SERVICE_NAME="llm-app-$(echo $STUDENT_EMAIL | cut -d'@' -f1 | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
  echo "Setting up: $STUDENT_EMAIL → $SERVICE_NAME"

  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$STUDENT_EMAIL" \
    --role="roles/run.developer" \
    --condition="expression=resource.name.startsWith(\"projects/$PROJECT_ID/locations/$REGION/services/$SERVICE_NAME\"),title=$SERVICE_NAME-only" \
    --quiet

  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$STUDENT_EMAIL" \
    --role="roles/cloudbuild.builds.editor" \
    --condition=None --quiet

  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$STUDENT_EMAIL" \
    --role="roles/artifactregistry.writer" \
    --condition="expression=resource.name.startsWith(\"projects/$PROJECT_ID/locations/$REGION/repositories/cloud-run-source-deploy/dockerImages/$SERVICE_NAME\"),title=$SERVICE_NAME-images-only" \
    --quiet

  gcloud iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
    --member="user:$STUDENT_EMAIL" \
    --role="roles/iam.serviceAccountUser" --quiet

done < student-emails.txt

echo "Done. All students provisioned."
