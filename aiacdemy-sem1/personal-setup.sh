#!/bin/bash
set -e

PROJECT_ID="project-cd9f1644-7a59-430b-ad4"
REGION="us-central1"
FUNCTION_NAME="auto-grant-creator"
FUNCTION_SA="eventarc-auto-grant@${PROJECT_ID}.iam.gserviceaccount.com"

echo "========================================"
echo " Personal Setup — Phase 4 Test"
echo " Project: $PROJECT_ID"
echo "========================================"
echo ""

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

# ─── Step 1: Enable APIs ──────────────────────────────────────────────────────
echo "--- Step 1: Enabling APIs ---"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  cloudfunctions.googleapis.com \
  eventarc.googleapis.com \
  pubsub.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  storage.googleapis.com \
  --project "$PROJECT_ID" --quiet
echo "  [OK] APIs enabled"

# ─── Step 2: Enable Data Access audit logs for Cloud Run ─────────────────────
echo ""
echo "--- Step 2: Enabling audit logs for Cloud Run ---"
gcloud projects get-iam-policy "$PROJECT_ID" --format=json > /tmp/policy-current.json
python3 - <<'PYEOF'
import json
with open('/tmp/policy-current.json') as f:
    policy = json.load(f)
configs = [c for c in policy.setdefault('auditConfigs', []) if c.get('service') != 'run.googleapis.com']
configs.append({'service': 'run.googleapis.com', 'auditLogConfigs': [
    {'logType': 'ADMIN_READ'}, {'logType': 'DATA_READ'}, {'logType': 'DATA_WRITE'}
]})
policy['auditConfigs'] = configs
with open('/tmp/policy-patched.json', 'w') as f:
    json.dump(policy, f)
PYEOF
gcloud projects set-iam-policy "$PROJECT_ID" /tmp/policy-patched.json --quiet 2>&1 | tail -1
echo "  [OK] Data Access audit logs enabled for run.googleapis.com"

# ─── Step 3: Create function service account ──────────────────────────────────
echo ""
echo "--- Step 3: Function Service Account ---"

gcloud iam service-accounts create eventarc-auto-grant \
  --display-name="Eventarc Auto-Grant Function SA" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || echo "  [OK] Service account already exists"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/run.admin" \
  --condition=None --quiet
echo "  [OK] run.admin granted to function SA"

# Eventarc SA: eventReceiver grants eventarc.events.receiveAuditLogWritten (auto-created on first use)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$EVENTARC_SA" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None --quiet 2>/dev/null || true
echo "  [OK] eventarc.eventReceiver granted to Eventarc SA"

# Pub/Sub SA needs token creator to authenticate push delivery to the function
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PUBSUB_SA" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --condition=None --quiet
echo "  [OK] iam.serviceAccountTokenCreator granted to Pub/Sub SA"

# Function SA needs eventReceiver for trigger validation
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None --quiet
echo "  [OK] eventarc.eventReceiver granted to function SA"

# Cloud Functions Gen2 builds run as the Compute SA — needs storage + AR + logging
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/storage.objectAdmin" \
  --condition=None --quiet
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/logging.logWriter" \
  --condition=None --quiet
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$COMPUTE_SA" \
  --role="roles/artifactregistry.writer" \
  --condition=None --quiet
echo "  [OK] storage.objectAdmin + logging.logWriter + artifactregistry.writer granted to Compute SA"

# ─── Step 4: Deploy Cloud Function ───────────────────────────────────────────
echo ""
echo "--- Step 4: Deploying Cloud Function ---"

gcloud functions deploy "$FUNCTION_NAME" \
  --gen2 \
  --runtime=python312 \
  --region="$REGION" \
  --source=./function \
  --entry-point=auto_grant \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
  --trigger-event-filters="serviceName=run.googleapis.com" \
  --trigger-event-filters="methodName=google.cloud.run.v2.Services.CreateService" \
  --service-account="$FUNCTION_SA" \
  --project="$PROJECT_ID" \
  --quiet
echo "  [OK] Cloud Function deployed: $FUNCTION_NAME"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " Done. To test:"
echo "   1. Deploy any Cloud Run service in this project"
echo "   2. Check function logs:"
echo "      gcloud functions logs read $FUNCTION_NAME --region=$REGION --project=$PROJECT_ID"
echo "   3. Verify the service got run.developer + allUsers:run.invoker"
echo "========================================"