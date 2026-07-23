#!/bin/bash
set -e

PROJECT_ID="cit-setup"
REGION="us-central1"
GROUP_EMAIL="product_team@revature.com"           # e.g. students@revature.com
FUNCTION_NAME="auto-grant-creator"
FUNCTION_SA="eventarc-auto-grant@${PROJECT_ID}.iam.gserviceaccount.com"

echo "========================================"
echo " Project Setup — run once per project"
echo " Project: $PROJECT_ID"
echo " Group:   $GROUP_EMAIL"
echo "========================================"
echo ""

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
EVENTARC_SA="service-${PROJECT_NUMBER}@gcp-sa-eventarc.iam.gserviceaccount.com"

# ─── Phase 1: Enable APIs ─────────────────────────────────────────────────────
echo "--- Phase 1: Enabling APIs ---"
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

# ─── Phase 2: Custom groupCreator role ────────────────────────────────────────
echo ""
echo "--- Phase 2: Custom IAM Role (groupCreator) ---"

cat > /tmp/group-creator-role.yaml << 'EOF'
title: "Group Creator"
description: "Create Cloud Run, AR, Storage, and Build resources. No modify or delete."
stage: GA
includedPermissions:
  - run.services.create
  - run.operations.get
  - artifactregistry.repositories.create
  - artifactregistry.repositories.get
  - artifactregistry.repositories.downloadArtifacts
  - storage.buckets.create
  - storage.buckets.get
  - storage.objects.create
  - cloudbuild.builds.create
  - cloudbuild.builds.get
  - logging.logEntries.list
EOF

gcloud iam roles create groupCreator \
  --project="$PROJECT_ID" \
  --file=/tmp/group-creator-role.yaml \
  --quiet 2>/dev/null || \
gcloud iam roles update groupCreator \
  --project="$PROJECT_ID" \
  --file=/tmp/group-creator-role.yaml \
  --quiet
echo "  [OK] groupCreator role created/updated"

# groupViewer: only run.services.list — granted per-user by Eventarc function
# after first deploy so each student can see their own service in the console.
cat > /tmp/group-viewer-role.yaml << 'EOF'
title: "Group Viewer"
description: "List Cloud Run services only. Granted per-user by Eventarc after deploy."
stage: GA
includedPermissions:
  - run.services.list
  - run.locations.list
EOF

gcloud iam roles create groupViewer \
  --project="$PROJECT_ID" \
  --file=/tmp/group-viewer-role.yaml \
  --quiet 2>/dev/null || \
gcloud iam roles update groupViewer \
  --project="$PROJECT_ID" \
  --file=/tmp/group-viewer-role.yaml \
  --quiet
echo "  [OK] groupViewer role created/updated"

# Assign groupCreator to the group
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="group:$GROUP_EMAIL" \
  --role="projects/$PROJECT_ID/roles/groupCreator" \
  --condition=None --quiet
echo "  [OK] groupCreator assigned to $GROUP_EMAIL"

# Allow group to use enabled GCP APIs (required for gcloud builds submit)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="group:$GROUP_EMAIL" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None --quiet
echo "  [OK] serviceUsageConsumer assigned to $GROUP_EMAIL"

# Allow group to stream Cloud Build logs in the terminal
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="group:$GROUP_EMAIL" \
  --role="roles/logging.viewer" \
  --condition=None --quiet
echo "  [OK] logging.viewer assigned to $GROUP_EMAIL"

# Allow group to use the Compute SA as Cloud Run runtime identity
gcloud iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
  --member="group:$GROUP_EMAIL" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID" --quiet
echo "  [OK] iam.serviceAccountUser on Compute SA assigned to $GROUP_EMAIL"

# ─── Phase 3: Function service account ────────────────────────────────────────
echo ""
echo "--- Phase 3: Function Service Account ---"

gcloud iam service-accounts create eventarc-auto-grant \
  --display-name="Eventarc Auto-Grant Function SA" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || echo "  [OK] Service account already exists"

# Function SA needs run.admin to call setIamPolicy and update labels on services
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/run.admin" \
  --condition=None --quiet
echo "  [OK] run.admin granted to function SA"

# Function SA needs to set project-level IAM to grant groupViewer (run.services.list)
# to each creator so they can see their service in the Cloud Run console
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/resourcemanager.projectIamAdmin" \
  --condition=None --quiet
echo "  [OK] projectIamAdmin granted to function SA"

# Function SA must actAs the Compute SA (the Cloud Run runtime identity) to
# update a service and stamp the owner=<email> billing label. Without this,
# update_service fails with 403 iam.serviceaccounts.actAs and the label is skipped.
gcloud iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID" --quiet
echo "  [OK] iam.serviceAccountUser on Compute SA granted to function SA"

PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

# Eventarc SA: eventReceiver grants eventarc.events.receiveAuditLogWritten
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$EVENTARC_SA" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None --quiet 2>/dev/null || true
echo "  [OK] eventarc.eventReceiver granted to Eventarc SA (auto-created on first use)"

# Pub/Sub SA needs token creator to authenticate push delivery to the function
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PUBSUB_SA" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --condition=None --quiet
echo "  [OK] iam.serviceAccountTokenCreator granted to Pub/Sub SA"

# Function SA that serves as Eventarc event receiver
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FUNCTION_SA" \
  --role="roles/eventarc.eventReceiver" \
  --condition=None --quiet
echo "  [OK] eventarc.eventReceiver granted to function SA"

# Cloud Functions Gen2 builds run as the Compute SA — it needs storage + AR + logging
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

# Enable Data Access audit logs for Cloud Run so Eventarc trigger validates
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

# ─── Phase 4: Deploy Cloud Function ───────────────────────────────────────────
echo ""
echo "--- Phase 4: Deploying Cloud Function ---"

gcloud functions deploy "$FUNCTION_NAME" \
  --gen2 \
  --runtime=python312 \
  --region="$REGION" \
  --source=./function \
  --entry-point=auto_grant \
  --trigger-event-filters="type=google.cloud.audit.log.v1.written" \
  --trigger-event-filters="serviceName=run.googleapis.com" \
  --trigger-event-filters="methodName=google.cloud.run.v1.Services.CreateService" \
  --service-account="$FUNCTION_SA" \
  --project="$PROJECT_ID" \
  --quiet
echo "  [OK] Cloud Function deployed: $FUNCTION_NAME"

# The deploy above created ONE trigger (v1 CreateService). But each Eventarc
# audit-log trigger matches exactly one methodName, and gcloud emits different
# method names depending on its version and whether it's a new deploy or a
# redeploy:
#   v1: CreateService / ReplaceService     v2: CreateService / UpdateService
# We add a trigger for each remaining method so EVERY deploy — any gcloud
# version, new or redeploy — fires the function. This is what makes isolation
# apply dynamically for all future users (newer clients use the v2 API, which
# the original v1-only trigger silently missed) and self-heal on redeploys.
EXTRA_METHODS=(
  "google.cloud.run.v2.Services.CreateService"
  "google.cloud.run.v1.Services.ReplaceService"
  "google.cloud.run.v2.Services.UpdateService"
)
mi=0
for M in "${EXTRA_METHODS[@]}"; do
  mi=$((mi + 1))
  gcloud eventarc triggers create "${FUNCTION_NAME}-m${mi}" \
    --location="$REGION" \
    --destination-run-service="$FUNCTION_NAME" \
    --destination-run-region="$REGION" \
    --destination-run-path="/" \
    --event-filters="type=google.cloud.audit.log.v1.written" \
    --event-filters="serviceName=run.googleapis.com" \
    --event-filters="methodName=${M}" \
    --service-account="$FUNCTION_SA" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null && echo "  [OK] trigger for ${M}" \
    || echo "  [OK] trigger for ${M} already exists"
done
echo "  [OK] All deploy-method triggers ensured (v1+v2, create+redeploy)"

# ─── Phase 5: Org Policies ────────────────────────────────────────────────────
echo ""
echo "--- Phase 5: Org Policies ---"

# Region lock — only us-central1
cat > /tmp/location-policy.json << EOF
{
  "constraint": "constraints/gcp.resourceLocations",
  "listPolicy": {
    "allowedValues": ["in:us-central1-locations"]
  }
}
EOF

gcloud resource-manager org-policies set-policy \
  /tmp/location-policy.json \
  --project="$PROJECT_ID" --quiet 2>/dev/null && \
  echo "  [OK] Region locked to us-central1" || \
  echo "  [SKIP] Location policy — requires org admin, set manually if needed"

# No public GCS buckets
gcloud resource-manager org-policies enable-enforce \
  constraints/storage.publicAccessPrevention \
  --project="$PROJECT_ID" --quiet 2>/dev/null && \
  echo "  [OK] Public bucket access prevented" || \
  echo "  [SKIP] Storage policy — requires org admin, set manually if needed"

echo ""
echo "NOTE: The 1 vCPU / 1 GB Cloud Run cap requires a custom org-policy"
echo "constraint at the organization level. Set it separately via:"
echo "  gcloud org-policies set-custom-constraint ..."
echo "  See: https://cloud.google.com/run/docs/configuring/org-policies"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " Setup complete."
echo ""
echo " What was configured:"
echo "   - APIs enabled"
echo "   - groupCreator + groupViewer custom roles created"
echo "   - groupCreator assigned → $GROUP_EMAIL"
echo "   - iam.serviceAccountUser on Compute SA → $GROUP_EMAIL"
echo "   - Eventarc function: $FUNCTION_NAME"
echo "   - Org policies (region + storage) applied"
echo ""
echo " What the function does on each deploy:"
echo "   1. Grants creator roles/run.developer on their service"
echo "   2. Grants allUsers roles/run.invoker (public browser access)"
echo "   3. Stamps owner=<email> label for billing tracking"
echo "========================================"