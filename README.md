# Vapor + Firebase Backend Template

A production-ready template for building Swift/Vapor backends on Google Cloud Run with Firebase/Firestore. Implements **Domain-Driven Design (DDD)** with **CQRS** patterns and includes a complete sample module demonstrating all architectural layers.

## Prerequisites

- **Swift 6.1+** (6.2 recommended)
- **Docker** (for containerized builds and deployment)
- **Google Cloud SDK** (`gcloud`) for Cloud Run deployment
- **Firebase CLI** for local emulator development
- A **GCP project** with Firestore enabled

## Quick Start

### 1. Clone and configure

```bash
git clone <this-repo> my-backend
cd my-backend
```

### 2. Set up environment

For local development with Firebase Emulators:

```bash
export GCP_PROJECT_ID=demo-project
export FIRESTORE_EMULATOR_HOST=localhost:9002
export FIREBASE_AUTH_EMULATOR_HOST=localhost:9099
```

For local development with a real GCP project:

```bash
export GCP_PROJECT_ID=your-project-id
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
```

### 3. Run locally

```bash
# With emulators (start Firebase emulators first)
firebase emulators:start

# In another terminal
swift run Run
```

### 4. Verify

```bash
curl http://localhost:8080/health   # → OK
curl http://localhost:8080/version  # → 0.0.1
curl http://localhost:8080/v1/items # → []
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `GCP_PROJECT_ID` | Yes | Google Cloud project ID |
| `GOOGLE_APPLICATION_CREDENTIALS` | Local only | Path to service account JSON (required outside Cloud Run/emulator) |
| `GCP_SERVICE_ACCOUNT_JSON_PATH` | Deprecated | Fallback for `GOOGLE_APPLICATION_CREDENTIALS`; logs a deprecation warning |
| `FIRESTORE_EMULATOR_HOST` | Emulator only | Firestore emulator (e.g., `localhost:9002`) |
| `FIREBASE_AUTH_EMULATOR_HOST` | Emulator only | Auth emulator (e.g., `localhost:9099`) |
| `PORT` | No | Server port (default: 8080) |
| `K_SERVICE` | Auto (Cloud Run) | Set automatically by Cloud Run |

## Architecture

```
Sources/VaporFirebaseBackendApp/
├── entrypoint.swift          # Application entry point
├── configure.swift           # App configuration and GCP bootstrap
├── routes.swift              # Route registration
├── App/                      # Application wiring (DI, GCP config)
├── Lib/                      # Generic DDD + CQRS infrastructure
├── Integration/              # Firestore, CloudRun, Eventarc
└── Modules/                  # Business modules
    └── Items/                # Sample module (replace with your domain)
```

Each module in `Modules/` follows the DDD layering: **Domain** (Entity, Event, Error, Repository protocol) → **Application** (Command/Query, UseCase, DTO, Mapper) → **Infrastructure** (Firestore Model, DataSource, Repository impl) → **Presentation** (Controller, Route).

For detailed architecture documentation — request flow, dependency injection, key patterns, and how to add modules — see [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md).

## Testing

```bash
# Run all tests
swift test

# Run a single test suite
swift test --filter CreateItemUseCaseTests

# Run with emulators for integration tests
FIRESTORE_EMULATOR_HOST=localhost:9002 GCP_PROJECT_ID=demo-project swift test
```

Tests use the Swift Testing framework with in-memory test doubles (no Firestore needed). See [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md#testing) for test patterns and available doubles.

## Deployment

### Local Docker

```bash
docker build -t my-backend .
docker run -p 8080:8080 -e GCP_PROJECT_ID=your-project my-backend
```

### Deploying to Cloud Run

This section walks through deploying the backend to Google Cloud Run with automated builds via Cloud Build, triggered on every push to your GitHub repository.

#### Prerequisites

- A [Google Cloud project](https://console.cloud.google.com/) with billing enabled
- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- Your repository hosted on GitHub

#### Step 1 — Enable GCP APIs

```bash
export PROJECT_ID=your-project-id

gcloud config set project $PROJECT_ID

gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  firestore.googleapis.com
```

#### Step 2 — Create an Artifact Registry repository

Artifact Registry stores your Docker images. Create a repository in your preferred region:

```bash
export REGION=us-central1
export SERVICE_NAME=my-backend

gcloud artifacts repositories create my-backend-repo \
  --repository-format=docker \
  --location=$REGION \
  --description="Docker images for my backend"
```

#### Step 3 — Set up Firestore

If you haven't already, create a Firestore database:

```bash
gcloud firestore databases create --location=$REGION
```

> **Note:** Firestore location cannot be changed after creation. Choose the same region as your Cloud Run service for lowest latency.

#### Step 4 — Grant Cloud Build permissions

Cloud Build needs permission to deploy to Cloud Run:

```bash
# Get the Cloud Build service account
BUILD_SA=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')@cloudbuild.gserviceaccount.com

# Grant Cloud Run Admin role
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$BUILD_SA" \
  --role="roles/run.admin"

# Grant Service Account User role (needed to act as the runtime service account)
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$BUILD_SA" \
  --role="roles/iam.serviceAccountUser"
```

#### Step 5 — Connect GitHub and create a Cloud Build trigger

1. Go to [Cloud Build Triggers](https://console.cloud.google.com/cloud-build/triggers) in the GCP Console
2. Click **Connect Repository** and follow the prompts to connect your GitHub repository
3. Click **Create Trigger** and configure:

| Setting | Value |
|---|---|
| **Name** | `deploy-on-push` (or your preference) |
| **Event** | Push to a branch |
| **Branch** | `^main$` (or your default branch) |
| **Configuration** | Cloud Build configuration file |
| **Location** | `cloudbuild.yaml` (repository root) |

4. Under **Substitution variables**, add:

| Variable | Value | Example |
|---|---|---|
| `_REGION` | Your GCP region | `us-central1` |
| `_REPOSITORY_NAME` | Artifact Registry repo name | `my-backend-repo` |
| `_SERVICE_NAME` | Cloud Run service name | `my-backend` |
| `_TAG` | Image tag | `$SHORT_SHA` |

> `$PROJECT_ID` and `$SHORT_SHA` are provided automatically by Cloud Build.

#### Step 6 — Deploy

**Option A: Automatic deployment (recommended)**

Push to your main branch. Cloud Build will automatically build, push, and deploy:

```bash
git push origin main
```

Monitor the build at [Cloud Build History](https://console.cloud.google.com/cloud-build/builds).

**Option B: Manual deployment**

Trigger a build manually from your local machine:

```bash
gcloud builds submit \
  --region=$REGION \
  --substitutions=_REGION=$REGION,_REPOSITORY_NAME=my-backend-repo,_SERVICE_NAME=$SERVICE_NAME,_TAG=manual
```

#### Step 7 — Verify

After the build completes (~5-15 minutes for the first build, faster with cache):

```bash
# Get the service URL
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region=$REGION --format='value(status.url)')

curl $SERVICE_URL/health   # → OK
curl $SERVICE_URL/version  # → 0.0.1
curl $SERVICE_URL/v1/items # → []
```

For details on how the Cloud Build pipeline works and production tuning, see [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md#cloud-build-pipeline).

## API Endpoints

### Built-in

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/version` | App version |
| POST | `/` | Eventarc webhook (CloudEvents) |

### Sample Items Module

| Method | Path | Description |
|---|---|---|
| GET | `/v1/items` | List all items |
| GET | `/v1/items/:itemId` | Get item by ID |
| POST | `/v1/items` | Create a new item |

**Create item payload:**
```json
{
  "name": "My Item",
  "description": "Optional description"
}
```
