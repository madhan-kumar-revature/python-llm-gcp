# Deployment Guide

## Overview

This app is a CLI-based LLM chatbot built with Python and Google Gemini. It is deployed to **Google Cloud Run** using **ttyd**, which wraps the CLI into a browser-accessible web terminal — no code changes required.

Each student gets their own independent Cloud Run service with a unique URL, derived from their Google account email.

---

## Prerequisites

### Tools Required

| Tool | Purpose | Install |
|---|---|---|
| `gcloud` CLI | Deploy to GCP | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| `Docker` | Not needed locally — Cloud Build handles it | — |

### GCP Setup (done once per student)

1. **Login to Google Cloud**
   ```bash
   gcloud auth login
   ```

2. **Set the project**
   ```bash
   gcloud config set project project-cd9f1644-7a59-430b-ad4
   ```

3. **Fix IAM permissions** (one-time, needed for Cloud Build to work)
   ```bash
   PROJECT_NUMBER=$(gcloud projects describe project-cd9f1644-7a59-430b-ad4 --format="value(projectNumber)")

   gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
     --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
     --role="roles/storage.objectAdmin" --condition=None

   gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
     --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
     --role="roles/artifactregistry.writer" --condition=None

   gcloud projects add-iam-policy-binding project-cd9f1644-7a59-430b-ad4 \
     --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
     --role="roles/logging.logWriter" --condition=None
   ```

### Project Files Required

| File | Description |
|---|---|
| `main.py` | Entry point — CLI loop |
| `llm_client.py` | Gemini API wrapper |
| `config.py` | Loads env vars |
| `requirements.txt` | Python dependencies |
| `.env` | Contains `GEMINI_API_KEY` and `MODEL_NAME` |
| `Dockerfile` | Container definition — installs ttyd and the app |
| `deploy.sh` | Deployment automation script |
| `.dockerignore` | Excludes `.venv`, `__pycache__`, `.env` from build |

### `.env` File Format

```
GEMINI_API_KEY=your_gemini_api_key_here
MODEL_NAME=gemini-2.5-flash
```

---

## GCP Services Used

| Service | Role |
|---|---|
| **Cloud Run** | Hosts and runs the containerised app. Auto-scales based on traffic. Each student gets one dedicated service. |
| **Cloud Build** | Builds the Docker image from source on every deploy. No local Docker needed. |
| **Artifact Registry** | Stores the built Docker image (`cloud-run-source-deploy` repository). |
| **Cloud Storage** | Temporarily holds the uploaded source zip during the build process. |
| **Cloud Logging** | Captures build logs from Cloud Build. |
| **IAM** | Controls which service accounts can read/write to each GCP service. |

---

## Deployment Flow

```
Student runs ./deploy.sh
        │
        ▼
1. Read student email from gcloud config
   → Derive unique service name (e.g. llm-app-john-doe)
        │
        ▼
2. Read GEMINI_API_KEY and MODEL_NAME from .env
        │
        ▼
3. gcloud run deploy --source .
        │
        ├─▶ Upload source code as zip → Cloud Storage bucket
        │
        ├─▶ Cloud Build pulls source from GCS
        │         │
        │         └─▶ docker build (using Dockerfile)
        │                   │
        │                   ├─▶ Install ttyd binary from GitHub releases
        │                   ├─▶ Copy app files
        │                   └─▶ pip install -r requirements.txt
        │
        ├─▶ Built image pushed → Artifact Registry
        │
        └─▶ Cloud Run creates/updates service
                  │
                  ├─▶ Injects GEMINI_API_KEY and MODEL_NAME as env vars
                  ├─▶ Sets port 7681 (ttyd web terminal)
                  ├─▶ Sets timeout to 3600s (1 hour sessions)
                  └─▶ Assigns public HTTPS URL
        │
        ▼
4. Print service URL to student
```

---

## Running the Deployment

```bash
chmod +x deploy.sh
./deploy.sh
```

**First run** — creates a new Cloud Run service and prints the URL.

**Subsequent runs** — updates the existing service with the latest code. The URL stays the same.

**Expected output:**
```
Deploying as: llm-app-john-doe
...
Your app is live at:
https://llm-app-john-doe-xxxxxxxxxx-uc.a.run.app
```

---

## What the Student Sees

Opening the URL in any browser shows a web terminal running the Python CLI directly:

```
LLM Assistant
Type 'exit' to quit

You: █
```

Each browser tab is an independent session. Multiple students can use the same service simultaneously without affecting each other.

---

## Cloud Run Configuration

| Parameter | Value | Reason |
|---|---|---|
| `--port` | `7681` | ttyd default web terminal port |
| `--concurrency` | `1` | One terminal session per container instance |
| `--min-instances` | `0` | Scales to zero when unused (cost saving) |
| `--timeout` | `3600` | Allows up to 1-hour interactive sessions |
| `--allow-unauthenticated` | enabled | Students access via browser without login |

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `storage.objects.get` 403 | Compute SA missing Storage Object Admin | Run IAM setup step 1 |
| `Build failed` on push | Compute SA missing Artifact Registry Writer | Run IAM setup step 2 |
| Empty build logs | Compute SA missing Logs Writer | Run IAM setup step 3 |
| `ttyd: command not found` | Using `apt-get install ttyd` (not in Debian repos) | Dockerfile downloads binary from GitHub releases |
| Session ends immediately | Cloud Run default timeout (60s) too short | `--timeout 3600` is set in deploy.sh |
