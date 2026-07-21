#!/bin/bash
set -e

PROJECT_ID="cit-setup"
REGION="us-central1"

# ─── Prerequisites Check ──────────────────────────────────────────────────────

PASS=true

check_tool() {
  if command -v "$1" &>/dev/null; then
    echo "  [OK] $1 is installed ($(command -v $1))"
  else
    echo "  [MISSING] $1 is not installed — $2"
    PASS=false
  fi
}

check_file() {
  if [ -f "$1" ]; then
    echo "  [OK] $1 found"
  else
    echo "  [MISSING] $1 not found — $2"
    PASS=false
  fi
}

check_env_var() {
  local VALUE
  VALUE=$(grep "^$1=" .env 2>/dev/null | cut -d'=' -f2)
  if [ -n "$VALUE" ]; then
    echo "  [OK] $1 is set in .env"
  else
    echo "  [MISSING] $1 is not set in .env — $2"
    PASS=false
  fi
}

echo "========================================"
echo " Prerequisites Check"
echo "========================================"

echo ""
echo ">> Tools"
check_tool gcloud  "Install from https://cloud.google.com/sdk/docs/install"
check_tool git     "Install from https://git-scm.com/downloads"
check_tool python3 "Install from https://www.python.org/downloads"
check_tool pip3    "Comes with Python — reinstall Python if missing"

echo ""
echo ">> GCP Authentication"
LOGGED_IN=$(gcloud config get-value account 2>/dev/null)
if [ -n "$LOGGED_IN" ] && [ "$LOGGED_IN" != "(unset)" ]; then
  echo "  [OK] Logged in as: $LOGGED_IN"
else
  echo "  [MISSING] Not logged in to gcloud — run: gcloud auth login"
  PASS=false
fi

echo ""
echo ">> Project Files"
check_file ".env" "Create a .env file with your LLM API key and MODEL_NAME"

echo ""
echo ">> Environment Variables (.env)"
check_env_var "GEMINI_API_KEY" "Add your LLM API key — GEMINI_API_KEY=your-key-here"
check_env_var "MODEL_NAME"     "Add your model name — MODEL_NAME=gemini-2.5-flash"
check_env_var "TTYD_USER"      "Add a terminal username — TTYD_USER=yourname"
check_env_var "TTYD_PASS"      "Add a terminal password — TTYD_PASS=yourpassword"

echo ""
if [ "$PASS" = false ]; then
  echo "  One or more prerequisites are missing. Fix the above and re-run."
  echo "========================================"
  exit 1
fi

echo "  All prerequisites passed."
echo "========================================"
echo ""

# ─── Auto-generate Dockerfile and .dockerignore if missing ───────────────────

if [ ! -f "Dockerfile" ]; then
  echo "Dockerfile not found — generating..."
  cat > Dockerfile <<'EOF'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y curl && \
    curl -L https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 \
    -o /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD ["sh", "-c", "ttyd --port 7681 --writable --credential \"${TTYD_USER}:${TTYD_PASS}\" python3 main.py"]
EOF
  echo "  [OK] Dockerfile created"
else
  echo "  [OK] Dockerfile already exists — skipping"
fi

if [ ! -f ".dockerignore" ]; then
  echo ".dockerignore not found — generating..."
  cat > .dockerignore <<'EOF'
.venv
__pycache__
*.pyc
.env
EOF
  echo "  [OK] .dockerignore created"
else
  echo "  [OK] .dockerignore already exists — skipping"
fi

echo ""

# ─── Derive per-student resource names ───────────────────────────────────────
# john.doe@gmail.com → john-doe
# Truncated to 20 chars so GCS bucket name stays under 63-char limit
STUDENT_EMAIL=$(gcloud config get-value account)
STUDENT_NAME=$(echo "$STUDENT_EMAIL" | cut -d'@' -f1 | tr '.' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-20)
SERVICE_NAME="llm-app-${STUDENT_NAME}"
AR_REPO="${SERVICE_NAME}"
SRC_BUCKET="llm-src-${STUDENT_NAME}-${PROJECT_ID}"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:latest"

# Read values from .env
GEMINI_API_KEY=$(grep '^GEMINI_API_KEY=' .env | cut -d'=' -f2)
MODEL_NAME=$(grep '^MODEL_NAME=' .env | cut -d'=' -f2)
MODEL_NAME="${MODEL_NAME:-gemini-2.5-flash}"
TTYD_USER=$(grep '^TTYD_USER=' .env | cut -d'=' -f2)
TTYD_PASS=$(grep '^TTYD_PASS=' .env | cut -d'=' -f2)

echo "Deploying as: $SERVICE_NAME"
echo ""

# ─── Create per-student Artifact Registry repository ─────────────────────────
# Uses try-create instead of describe-then-create — describe needs
# artifactregistry.repositories.get which is removed to prevent cross-student visibility.
AR_OUT=$(gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>&1) && \
  echo "  [OK] Repository created: $AR_REPO" || {
  if echo "$AR_OUT" | grep -qi "already exist"; then
    echo "  [OK] Repository already exists: $AR_REPO"
  else
    echo "  [ERROR] $AR_OUT"; exit 1
  fi
}

# ─── Create per-student Cloud Storage bucket ──────────────────────────────────
# Uses try-create instead of checking existence — avoids needing storage.buckets.list.
# Uses gcloud storage instead of gsutil — no separate Python version dependency.
GCS_OUT=$(gcloud storage buckets create "gs://${SRC_BUCKET}" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --quiet 2>&1) && \
  echo "  [OK] Bucket created: gs://${SRC_BUCKET}" || {
  if echo "$GCS_OUT" | grep -qi "already exist\|409"; then
    echo "  [OK] Bucket already exists: gs://${SRC_BUCKET}"
  else
    echo "  [ERROR] $GCS_OUT"; exit 1
  fi
}

echo ""

# ─── Build Docker image via Cloud Build ──────────────────────────────────────
echo "Building Docker image..."
BUILD_ID=$(gcloud builds submit . \
  --tag "$IMAGE_URI" \
  --gcs-source-staging-dir "gs://${SRC_BUCKET}/source" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --async \
  --format="value(id)")

echo "  Build submitted: $BUILD_ID"
echo "  Waiting for build to complete..."

while true; do
  STATUS=$(gcloud builds describe "$BUILD_ID" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --format="value(status)")
  case "$STATUS" in
    SUCCESS)
      echo "  [OK] Build succeeded"
      break
      ;;
    FAILURE|CANCELLED|TIMEOUT|INTERNAL_ERROR)
      echo "  [FAILED] Build failed — status: $STATUS"
      echo "  Logs: https://console.cloud.google.com/cloud-build/builds;region=${REGION}/${BUILD_ID}?project=${PROJECT_ID}"
      exit 1
      ;;
    *)
      echo "  ... $STATUS"
      sleep 10
      ;;
  esac
done

echo ""

# ─── Deploy to Cloud Run ──────────────────────────────────────────────────────
echo "Deploying to Cloud Run..."
SERVICE_URL=$(gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE_URI" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --port 7681 \
  --concurrency 1 \
  --min-instances 0 \
  --timeout 3600 \
  --set-env-vars GEMINI_API_KEY="$GEMINI_API_KEY",MODEL_NAME="$MODEL_NAME",TTYD_USER="$TTYD_USER",TTYD_PASS="$TTYD_PASS" \
  --format="value(status.url)")

echo ""
# URL is captured from the deploy response directly.
# 'gcloud run services describe' was removed — run.services.get is no longer in
# groupCreator (to prevent cross-student env var visibility), and Eventarc hasn't
# granted run.developer yet at this point in the script.
echo "Your app is live at: $SERVICE_URL"
