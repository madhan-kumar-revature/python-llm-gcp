# GCP Console Deployment Guide

Deploy the LLM app to Cloud Run entirely through the GCP Console UI — no terminal commands.

**Console URL:** https://console.cloud.google.com
**Project:** `project-cd9f1644-7a59-430b-ad4`

---

## Step 1 — Select Your Project

1. Open https://console.cloud.google.com
2. Click the **project dropdown** at the top (next to "Google Cloud" logo)
3. Search for `project-cd9f1644-7a59-430b-ad4`
4. Click it to switch into the project

---

## Step 2 — Enable Required APIs

### Enable Cloud Run
1. Go to **Navigation Menu (☰) → APIs & Services → Library**
2. Search: `Cloud Run Admin API`
3. Click the result → Click **Enable**

### Enable Cloud Build
1. Search: `Cloud Build API`
2. Click → **Enable**

### Enable Artifact Registry
1. Search: `Artifact Registry API`
2. Click → **Enable**

> **Verify:** Go to **APIs & Services → Enabled APIs & Services**
> All three should appear in the list.

---

## Step 3 — Fix IAM Permissions

1. Go to **Navigation Menu (☰) → IAM & Admin → IAM**
2. Find the service account: `1037166449498-compute@developer.gserviceaccount.com`
   - If not visible, check **Include Google-provided role grants** checkbox
3. Click the **pencil icon** (Edit) on that row
4. Click **+ Add Another Role** → search and add each of the following:
   - `Storage Object Admin`
   - `Artifact Registry Writer`
   - `Logs Writer`
5. Click **Save**

> **Verify:** The row for that service account should now show all 3 roles.

---

## Step 4 — Create Artifact Registry Repository

1. Go to **Navigation Menu (☰) → Artifact Registry → Repositories**
2. Click **+ Create Repository**
3. Fill in:
   - **Name:** `cloud-run-source-deploy`
   - **Format:** `Docker`
   - **Mode:** `Standard`
   - **Region:** `us-central1`
4. Click **Create**

> **Verify:** Repository appears in the list with format `Docker` and region `us-central1`

---

## Step 5 — Upload Source Code via Cloud Shell

Since files are on your local machine, use Cloud Shell to get them into GCP.

1. Click the **Cloud Shell icon (>_)** in the top-right toolbar of the Console
   > A terminal opens at the bottom of the screen

2. In Cloud Shell, click the **three-dot menu (⋮) → Upload**
3. Select and upload all project files:
   - `main.py`
   - `llm_client.py`
   - `config.py`
   - `requirements.txt`
   - `Dockerfile`
   - `.dockerignore`
   - `.env`

4. In the Cloud Shell terminal, verify files arrived:
   ```bash
   ls -la
   ```

---

## Step 6 — Trigger a Cloud Build

Build the Docker image from your uploaded source.

1. In Cloud Shell, run:
   ```bash
   gcloud builds submit . \
     --tag us-central1-docker.pkg.dev/project-cd9f1644-7a59-430b-ad4/cloud-run-source-deploy/llm-app-console \
     --region us-central1
   ```
   > This packages your files, sends them to Cloud Build, and pushes the image to Artifact Registry.

2. **Watch the build in Console:**
   - Go to **Navigation Menu (☰) → Cloud Build → Build History**
   - Click the running build
   - You'll see live step-by-step output:
     - `Step 0` — Pulls Docker builder
     - `Step 1` — Runs `docker build` (installs ttyd, copies files, pip install)
     - `Step 2` — Pushes image to Artifact Registry

> **Verify:** Build status turns green ✓ with `SUCCESS`

---

## Step 7 — Verify Image in Artifact Registry

1. Go to **Navigation Menu (☰) → Artifact Registry → Repositories**
2. Click **cloud-run-source-deploy**
3. You'll see: `llm-app-console` with tag `latest`
4. Click the image name → you'll see the digest, size, and when it was pushed

> This is the Docker image Cloud Run will pull and run.

---

## Step 8 — Create the Cloud Run Service

1. Go to **Navigation Menu (☰) → Cloud Run**
2. Click **+ Create Service**

### Container Settings
- **Select:** `Deploy one revision from an existing container image`
- Click **Select** → Browse to:
  `us-central1-docker.pkg.dev/project-cd9f1644-7a59-430b-ad4/cloud-run-source-deploy/llm-app-console`
- Select the `latest` tag → Click **Select**

### Service Configuration
- **Service name:** `llm-app-console`
- **Region:** `us-central1 (Iowa)`

### Authentication
- Select: **Allow unauthenticated invocations**

### Click "Container, Networking, Security" to expand advanced settings:

#### Container Tab
- **Container port:** `7681`
- **Request timeout:** `3600` seconds

#### Environment Variables
- Click **+ Add Variable** for each:
  - Name: `GEMINI_API_KEY` → Value: *(your Gemini API key from .env)*
  - Name: `MODEL_NAME` → Value: `gemini-2.5-flash`

#### Capacity Tab
- **Maximum concurrent requests per instance:** `1`
- **Minimum instances:** `0`
- **Maximum instances:** `10`

3. Click **Create**

> Cloud Run will pull the image from Artifact Registry and start the container.

---

## Step 9 — Watch the Deployment

After clicking Create, you land on the service detail page.

- **Status circle** — spins while deploying, turns green ✓ when live
- **Revisions tab** — shows `llm-app-console-00001-xxx` being created
- **Logs tab** — shows container startup: ttyd binding to port 7681

Wait for the green checkmark at the top of the page.

---

## Step 10 — Get Your URL and Test

1. On the Cloud Run service page, the **URL is shown at the top:**
   ```
   https://llm-app-console-xxxxxxxxxx-uc.a.run.app
   ```
2. Click the URL → browser opens your Python CLI as a web terminal
3. Type a question and press Enter
4. Verify you get a response from Gemini

---

## Step 11 — Monitor Live Traffic

### Check Logs
1. **Cloud Run → llm-app-console → Logs tab**
2. After asking a question in the browser, you'll see the request logged

### Check Metrics
1. **Cloud Run → llm-app-console → Metrics tab**
2. You'll see:
   - **Request count** — spikes when you send a message
   - **Container instance count** — goes from 0 → 1 when first request arrives
   - **Request latency** — time taken per Gemini API call

---

## Step 12 — Cleanup via Console

### Delete Cloud Run Service
1. **Cloud Run → Services**
2. Check the box next to `llm-app-console`
3. Click **Delete** → Confirm

### Delete Image from Artifact Registry
1. **Artifact Registry → cloud-run-source-deploy**
2. Check the box next to `llm-app-console`
3. Click **Delete** → Confirm

### Remove IAM Roles
1. **IAM & Admin → IAM**
2. Find `1037166449498-compute@developer.gserviceaccount.com`
3. Click **Edit (pencil icon)**
4. Click the **X** next to each role added:
   - Storage Object Admin
   - Artifact Registry Writer
   - Logs Writer
5. Click **Save**

---

## Console Navigation Reference

| What you need | Where to go |
|---|---|
| Enable APIs | APIs & Services → Library |
| Set permissions | IAM & Admin → IAM |
| View build logs | Cloud Build → Build History |
| View Docker images | Artifact Registry → Repositories |
| Deploy and manage app | Cloud Run → Services |
| View app logs | Cloud Run → [service] → Logs |
| Upload local files | Cloud Shell (>_ icon) → ⋮ → Upload |
