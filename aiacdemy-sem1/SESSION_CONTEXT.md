# Session Context — LLM Chatbot GCP Deployment

## Project Overview

Deploy a Python CLI LLM chatbot (Google Gemini + ttyd browser terminal) to GCP Cloud Run
for ~800 students with full per-student resource isolation.

- **GCP Project**: `cit-setup`
- **Region**: `us-central1`
- **Group**: `product_team@revature.com`
- **Public Repo** (for students without GitHub login): `python-LLM` on GitHub
- **Mirror path**: `/Users/madhan.kumar/Madhan/python-LLM/aiacdemy-sem1/` ← sync here after every change

---

## Per-Student Resources (all isolated)

| Resource | Naming Pattern |
|----------|---------------|
| Cloud Run service | `llm-app-<student-name>` |
| Artifact Registry repo | `llm-app-<student-name>` |
| GCS bucket | `llm-src-<student-name>-cit-setup` |
| Cloud Build job | submitted per deploy |

`<student-name>` = first 20 chars of email prefix, dots replaced with hyphens.
e.g. `madhan.kumar@revature.com` → `madhan-kumar`

---

## Architecture

```
Student runs deploy.sh
    │
    ├─ AR repo create (try-create, no list/get)
    ├─ GCS bucket create (try-create, no list)
    ├─ Cloud Build → builds image → pushes to AR
    └─ REST API POST /v2/services (first deploy, no run.services.get needed)
           └─ 409 → REST API PATCH /v2/services/{name} (redeploy)
                │
                └─ Eventarc fires (auto-grant-creator function)
                        ├─ Grants run.developer on service → student
                        ├─ Grants allUsers run.invoker on service (public access)
                        ├─ Grants groupViewer at project level → student
                        └─ Stamps owner=<email> label on service
```

### Why REST API instead of `gcloud run deploy`

`gcloud run deploy` always calls `run.services.get` before create/update.
Students don't have `run.services.get` (intentionally removed — it exposes env vars of
other students' services via `gcloud run services describe`). The REST API
`POST /v2/services?serviceId=NAME` creates a service with only `run.services.create`.

---

## IAM Design

### Group-level roles (`product_team@revature.com`)

| Role | Why |
|------|-----|
| `projects/cit-setup/roles/groupCreator` | Create Cloud Run, AR, GCS, Build resources |
| `roles/serviceusage.serviceUsageConsumer` | Use GCP APIs (needed for gcloud builds submit) |
| `roles/logging.viewer` | Stream Cloud Build logs in terminal |
| `roles/iam.serviceAccountUser` on Compute SA | Cloud Run runtime identity |

### groupCreator permissions (custom role)

```
run.services.create
run.operations.get
artifactregistry.repositories.create
artifactregistry.repositories.get
artifactregistry.repositories.downloadArtifacts
storage.buckets.create
storage.buckets.get
storage.objects.create
cloudbuild.builds.create
cloudbuild.builds.get
logging.logEntries.list
```

**Deliberately excluded**: `run.services.get`, `run.services.list`, `run.services.update`,
`run.services.delete` — prevents cross-student visibility and modification.

### groupViewer permissions (custom role — NOT on group, granted per-user by Eventarc)

```
run.services.list
run.locations.list     ← required by Cloud Run console to discover regions
```

`run.locations.list` was discovered as required — without it, console shows
"Permission 'run.locations.list' denied" even if `run.services.list` is present.

### Per-user grants (applied by Eventarc function after first deploy)

| Role | Scope | Effect |
|------|-------|--------|
| `roles/run.developer` | service level | Student can redeploy their own service |
| `roles/run.invoker` (allUsers) | service level | Public browser access via ttyd |
| `projects/cit-setup/roles/groupViewer` | project level | Console list view |

---

## Eventarc Function (`auto-grant-creator`)

**File**: `function/main.py`
**SA**: `eventarc-auto-grant@cit-setup.iam.gserviceaccount.com`
**SA roles**: `run.admin`, `resourcemanager.projectIamAdmin`, `iam.serviceAccountUser` on Compute SA

### What it does on every deploy event

1. Filters out service-account-initiated events (loop guard — function's own label-stamp triggers UpdateService)
2. Converts v1 audit log resource name (`namespaces/...`) to v2 format (`projects/.../locations/.../services/...`)
3. Grants `run.developer` + `allUsers:run.invoker` at service level
4. Grants `groupViewer` at project level (`_grant_list_permission`)
5. Stamps `owner=<sanitized-email>` label on service (`_stamp_owner_label`)

### Eventarc triggers (covers v1 + v2 API, create + redeploy)

| Trigger | Method |
|---------|--------|
| auto-grant-creator | `google.cloud.run.v1.Services.CreateService` |
| auto-grant-creator-m1 | `google.cloud.run.v2.Services.CreateService` |
| auto-grant-creator-m2 | `google.cloud.run.v1.Services.ReplaceService` |
| auto-grant-creator-m3 | `google.cloud.run.v2.Services.UpdateService` |

---

## Key Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-time admin setup — roles, IAM, Eventarc function deploy |
| `deploy.sh` | Per-student deploy script — AR, GCS, Cloud Build, Cloud Run |
| `function/main.py` | Eventarc auto-grant function |
| `function/requirements.txt` | Function dependencies |
| `main.py` | Student's LLM chatbot (Python CLI) |
| `cleanup.sh` | Admin cleanup of per-student resources |

---

## deploy.sh — Key Design Decisions

- **Token fetched in bash** (`TOKEN=$(gcloud auth print-access-token)`) and passed to Python
  via env var. Do NOT call `gcloud` via subprocess inside Python — fails on Windows
  (gcloud is a `.cmd` file, not directly executable by subprocess without `shell=True`).

- **AR repo + GCS bucket**: try-create pattern (no describe/list first) — students lack
  list permissions by design.

- **Cloud Build**: `--async` submit + polling loop with `gcloud builds describe`.

- **Cloud Run**: REST API `POST` → 409 → `PATCH` with LRO polling.

- **No `ENV` in Dockerfile**: env vars injected at Cloud Run runtime only. Baking into
  Dockerfile is less secure — students can `downloadArtifacts` (needed for build), so
  any student could pull and inspect any image.

---

## Issues Resolved This Session

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| `run.services.get` PERMISSION_DENIED | `gcloud run deploy` always GETs first | Replaced with REST API POST/PATCH |
| Console "no permission to list" | `groupViewer` missing `run.locations.list` | Added to groupViewer role in setup.sh |
| Windows deploy failure | Python subprocess can't find `gcloud.cmd` | Token fetched in bash, passed via env var |
| `groupViewer` not granted (old logs) | Function was old version without `_grant_list_permission` | Redeployed function via setup.sh |
| `could not set owner label` | Service still reconciling when function stamps label | Known/minor — label may be missed on very fast triggers |

---

## Sync Rule

**After every change to any file in `/Users/madhan.kumar/Madhan/aiacademy-sem1/`**,
sync to `/Users/madhan.kumar/Madhan/python-LLM/aiacdemy-sem1/` and push.

```bash
# Quick sync command
cp -r /Users/madhan.kumar/Madhan/aiacademy-sem1/{setup.sh,deploy.sh,function} \
      /Users/madhan.kumar/Madhan/python-LLM/aiacdemy-sem1/

# Verify
diff -rq /Users/madhan.kumar/Madhan/aiacademy-sem1/ \
         /Users/madhan.kumar/Madhan/python-LLM/aiacdemy-sem1/ \
         --exclude="__pycache__" --exclude=".env" --exclude=".git" --exclude=".dockerignore"

# Commit and push
cd /Users/madhan.kumar/Madhan/python-LLM
git add aiacdemy-sem1/
git commit -m "sync: <describe change>"
git push
```

---

## Current State (end of session)

- `setup.sh` — fully configured, includes `run.locations.list` in groupViewer, extra Eventarc triggers
- `deploy.sh` — REST API approach, Windows-compatible token fetch
- `function/main.py` — handles v1+v2 API methods, loop guard for self-trigger, grants groupViewer
- Both directories in sync
- madhan.kumar's service `llm-app-madhan-kumar` deployed and accessible
- `_stamp_owner_label` still occasionally fails (service reconciling) — non-critical

## Open Items

- `_stamp_owner_label` failure — minor, cosmetic. Service label may not be set if the
  function fires before the service finishes reconciling. No student-facing impact.