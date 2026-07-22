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

# Uses Cloud Run v2 REST API directly via Python (no gcloud run deploy).
# gcloud run deploy calls run.services.get before creating — students don't
# have that permission (prevents cross-student env var visibility).
# POST /services  → run.services.create only (first deploy)
# PATCH /services → run.services.update only (redeploy, via run.developer from Eventarc)
SERVICE_URL=$(PROJECT_ID="$PROJECT_ID" REGION="$REGION" SERVICE_NAME="$SERVICE_NAME" \
  IMAGE_URI="$IMAGE_URI" GEMINI_API_KEY="$GEMINI_API_KEY" MODEL_NAME="$MODEL_NAME" \
  TTYD_USER="$TTYD_USER" TTYD_PASS="$TTYD_PASS" \
  python3 - <<'PYEOF'
import json, os, sys, time, subprocess, urllib.request, urllib.error

def get_token():
    r = subprocess.run(["gcloud", "auth", "print-access-token"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()

def call(method, url, token, body=None):
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())

token   = get_token()
project = os.environ["PROJECT_ID"]
region  = os.environ["REGION"]
svc     = os.environ["SERVICE_NAME"]
base    = f"https://run.googleapis.com/v2/projects/{project}/locations/{region}/services"

body = {
    "template": {
        "containers": [{
            "image": os.environ["IMAGE_URI"],
            "ports": [{"containerPort": 7681}],
            "env": [{"name": k, "value": os.environ[k]}
                    for k in ["GEMINI_API_KEY", "MODEL_NAME", "TTYD_USER", "TTYD_PASS"]],
            "resources": {"limits": {"cpu": "1000m", "memory": "512Mi"}}
        }],
        "maxInstanceRequestConcurrency": 1,
        "scaling": {"minInstanceCount": 0},
        "timeout": "3600s"
    },
    "ingress": "INGRESS_TRAFFIC_ALL"
}

# First deploy: POST (run.services.create — in groupCreator)
status, resp = call("POST", f"{base}?serviceId={svc}", token, body)

if status == 409:
    # Redeploy: PATCH (run.services.update — in run.developer granted by Eventarc)
    print("  Service exists — redeploying...", file=sys.stderr, flush=True)
    body["name"] = f"projects/{project}/locations/{region}/services/{svc}"
    status, resp = call("PATCH", f"{base}/{svc}", token, body)

if status not in (200, 201):
    msg = resp.get("error", {}).get("message", str(resp))
    print(f"  [ERROR] {msg}", file=sys.stderr)
    sys.exit(1)

# Poll LRO until service is ready
op = resp.get("name", "")
print("  Waiting for service to be ready...", file=sys.stderr, flush=True)
for _ in range(72):  # up to 6 minutes
    time.sleep(5)
    _, state = call("GET", f"https://run.googleapis.com/v2/{op}", token)
    if state.get("done"):
        if "error" in state:
            print(f"  [ERROR] {state['error']}", file=sys.stderr)
            sys.exit(1)
        print(state.get("response", {}).get("uri", ""))
        sys.exit(0)
    print("  ...", file=sys.stderr, flush=True)

print("  [ERROR] Timed out waiting for deployment", file=sys.stderr)
sys.exit(1)
PYEOF
)

echo ""
echo "Your app is live at: $SERVICE_URL"
