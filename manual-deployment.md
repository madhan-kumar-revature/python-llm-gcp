# Manual Deployment Guide

Run each command one by one. After each step, a **Console Check** tells you exactly where to look in the GCP Console to verify it worked.

---

## Step 0 — Authenticate and Set Project

```bash
gcloud auth login
```
> Opens browser. Sign in with your Google account.

```bash
gcloud config set project project-cd9f1644-7a59-430b-ad4
```

```bash
gcloud config get-value account
```
> Confirms your logged-in email. This is used to name your Cloud Run service.

**Console Check:**
- Go to: https://console.cloud.google.com
- Top-left dropdown → confirm project is `project-cd9f1644-7a59-430b-ad4`

---

## Step 1 — Enable Required APIs

```bash
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  --project project-cd9f1644-7a59-430b-ad4
```
> Safe to run repeatedly — no-op if already enabled. The automated `deploy.sh` does this silently. When using `gcloud run deploy` interactively, the CLI auto-prompts to enable missing APIs. Here we make it explicit so nothing is left to chance.

**Console Check:**
- Go to: **APIs & Services → Enabled APIs**
- Search for: `Cloud Run`, `Cloud Build`, `Artifact Registry`
- All three should appear as Enabled

---

## Step 2 — Fix IAM Permissions (One-time Setup)

Get the project number first:
```bash
gcloud projects describe project-cd9f1644-7a59-430b-ad4 --format="value(projectNumber)"
```
> Output: `1037166449498` — note this number, used in commands below.

Grant Storage access (so Cloud Build can read your uploaded source):
```bash
gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
  --member="serviceAccount:1037166449498-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectAdmin" \
  --condition=None
```

Grant Artifact Registry access (so Cloud Build can push the built image):
```bash
gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
  --member="serviceAccount:1037166449498-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.writer" \
  --condition=None
```

Grant Logging access (so Cloud Build can write build logs):
```bash
gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
  --member="serviceAccount:1037166449498-compute@developer.gserviceaccount.com" \
  --role="roles/logging.logWriter" \
  --condition=None
```

**Console Check:**
- Go to: **IAM & Admin → IAM**
- Find: `1037166449498-compute@developer.gserviceaccount.com`
- Verify roles: `Storage Object Admin`, `Artifact Registry Writer`, `Logs Writer`

---

## Step 3 — Confirm Project Files Are Ready

```bash
ls -la
```
> You should see: `main.py`, `llm_client.py`, `config.py`, `requirements.txt`, `.env`, `Dockerfile`, `.dockerignore`

```bash
cat Dockerfile
```
> Verify the Dockerfile downloads `ttyd` from GitHub and runs `python3 main.py`

```bash
cat .dockerignore
```
> Verify `.venv`, `__pycache__`, `.env` are excluded from the build

```bash
cat requirements.txt
```
> Should list `google-genai` and `python-dotenv`

---

## Step 4 — Upload Source to Cloud Storage

This happens automatically as part of `gcloud run deploy --source`, but you can watch it:

```bash
gcloud run deploy llm-app-manual-test \
  --source . \
  --project project-cd9f1644-7a59-430b-ad4 \
  --region us-central1 \
  --no-traffic \
  --allow-unauthenticated \
  --port 7681 \
  --timeout 3600 \
  --async
```
> `--async` returns immediately. `--no-traffic` deploys without routing traffic yet.

**Console Check — Cloud Storage:**
- Go to: **Cloud Storage → Buckets**
- Find bucket: `run-sources-project-cd9f1644-7a59-430b-ad4-us-central1`
- Open it → `services/` folder → you'll see a `.zip` of your source code uploaded

---

## Step 5 — Watch the Cloud Build

```bash
gcloud builds list \
  --project=project-cd9f1644-7a59-430b-ad4 \
  --region=us-central1 \
  --limit=5
```
> Lists recent builds. Note the `ID` of the running build.

```bash
gcloud builds log <BUILD_ID> \
  --region=us-central1 \
  --project=project-cd9f1644-7a59-430b-ad4
```
> Replace `<BUILD_ID>` with the ID from above. Shows the live Docker build output.

**Console Check — Cloud Build:**
- Go to: **Cloud Build → Build History**
- Click the latest build
- Watch the build steps live:
  - `apt-get install` → downloads ttyd
  - `pip install` → installs Python packages
  - `docker push` → pushes image to Artifact Registry

---

## Step 6 — Verify Image in Artifact Registry

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/project-cd9f1644-7a59-430b-ad4/cloud-run-source-deploy \
  --project=project-cd9f1644-7a59-430b-ad4
```
> Should show your `llm-app-*` image with a digest and timestamp.

**Console Check — Artifact Registry:**
- Go to: **Artifact Registry → Repositories**
- Open: `cloud-run-source-deploy` (region: `us-central1`)
- You'll see the Docker image with its tag `latest` and size

---

## Step 7 — Deploy to Cloud Run (with traffic)

```bash
gcloud run deploy llm-app-manual-test \
  --source . \
  --project project-cd9f1644-7a59-430b-ad4 \
  --region us-central1 \
  --allow-unauthenticated \
  --port 7681 \
  --concurrency 1 \
  --min-instances 0 \
  --timeout 3600 \
  --set-env-vars GEMINI_API_KEY=your-key-here,MODEL_NAME=gemini-2.5-flash
```
> This rebuilds and routes 100% traffic to the new revision.

**Console Check — Cloud Run:**
- Go to: **Cloud Run → Services**
- Click `llm-app-manual-test`
- You'll see:
  - **Revisions** tab → `llm-app-manual-test-00001-xxx` with 100% traffic
  - **Logs** tab → container startup logs from ttyd
  - **Details** tab → URL, region, concurrency, timeout settings

---

## Step 8 — Get the Service URL

```bash
gcloud run services describe llm-app-manual-test \
  --project=project-cd9f1644-7a59-430b-ad4 \
  --region=us-central1 \
  --format="value(status.url)"
```
> Prints your live URL. Open it in the browser.

**Console Check:**
- Go to: **Cloud Run → Services → llm-app-manual-test**
- URL is shown at the top of the service detail page
- Click it → your Python CLI should appear as a web terminal

---

## Step 9 — Check Logs After Using the App

After typing a question in the browser terminal:

```bash
gcloud run services logs read llm-app-manual-test \
  --project=project-cd9f1644-7a59-430b-ad4 \
  --region=us-central1 \
  --limit=50
```

**Console Check:**
- Go to: **Cloud Run → Services → llm-app-manual-test → Logs**
- You'll see each request logged with timestamp, container instance, and response time

---

## Step 10 — Cleanup After Testing

Delete the Cloud Run service:
```bash
gcloud run services delete llm-app-manual-test \
  --project=project-cd9f1644-7a59-430b-ad4 \
  --region=us-central1 \
  --quiet
```

Delete the image from Artifact Registry:
```bash
gcloud artifacts docker images delete \
  us-central1-docker.pkg.dev/project-cd9f1644-7a59-430b-ad4/cloud-run-source-deploy/llm-app-manual-test \
  --project=project-cd9f1644-7a59-430b-ad4 \
  --quiet \
  --delete-tags
```

Delete source zips from Cloud Storage:
```bash
gsutil -m rm -r \
  gs://run-sources-project-cd9f1644-7a59-430b-ad4-us-central1/services/llm-app-manual-test
```

**Console Check:**
- **Cloud Run** → service should be gone
- **Artifact Registry** → image should be gone
- **Cloud Storage** → service folder should be gone

---

## Full Deployment Flow (Reference)

```
gcloud auth login
        │
        ▼
Source uploaded → Cloud Storage bucket
        │
        ▼
Cloud Build pulls source → docker build (Dockerfile)
        │   ├── apt-get install ttyd
        │   ├── COPY app files
        │   └── pip install requirements.txt
        │
        ▼
Built image pushed → Artifact Registry
        │
        ▼
Cloud Run pulls image → creates Revision
        │   ├── Injects env vars (GEMINI_API_KEY, MODEL_NAME)
        │   ├── Opens port 7681
        │   └── Starts ttyd → wraps python3 main.py
        │
        ▼
HTTPS URL assigned → browser opens web terminal
```
