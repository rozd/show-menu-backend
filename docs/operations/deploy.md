# Deploying to GCP (show-menu-dev)

Flow: Conventional Commits on `main` -> release-please maintains a release PR -> merging it
tags `vX.Y.Z` -> Cloud Build trigger `production-deploy` (`.infra/triggers/`) runs
`cloudbuild.yaml` -> Cloud Run service `show-menu-backend` (europe-west1).

Always pass `--project=show-menu-dev` to gcloud; a developer's active config may point elsewhere.

## Releasing
1. Merge PRs with Conventional Commit titles (`feat:`, `fix:`, ...); `scripts/ci/check_conventional_commits.py` enforces it.
2. Review and merge the "release X.Y.Z" PR that release-please opens.
3. Watch the build: `gcloud builds list --project=show-menu-dev --region=europe-west1 --limit=3`.
4. Manual deploy (no tag): `gcloud builds submit --project=show-menu-dev --config=cloudbuild.yaml --substitutions=_TAG=manual-$(git rev-parse --short HEAD)`.
5. Rollback: `gcloud run services update-traffic show-menu-backend --project=show-menu-dev --region=europe-west1 --to-revisions=<REVISION>=100`.

## One-time bootstrap
Prerequisite: **billing enabled** on `show-menu-dev` (Artifact Registry, Cloud Build, Scheduler need it).

```bash
P=show-menu-dev; R=europe-west1
gcloud services enable cloudbuild run artifactregistry secretmanager cloudscheduler eventarc cloudfunctions iamcredentials --project=$P
gcloud artifacts repositories create show-menu-backend-repo --repository-format=docker --location=$R --project=$P
gcloud iam service-accounts create show-menu-api --project=$P          # runtime identity
gcloud iam service-accounts create show-menu-scheduler --project=$P    # Cloud Scheduler caller
for role in roles/datastore.user roles/secretmanager.secretAccessor roles/iam.serviceAccountTokenCreator; do
  gcloud projects add-iam-policy-binding $P --member=serviceAccount:show-menu-api@$P.iam.gserviceaccount.com --role=$role
done
printf '%s' "<public key>"  | gcloud secrets create LIQPAY_PUBLIC_KEY  --data-file=- --project=$P
printf '%s' "<private key>" | gcloud secrets create LIQPAY_PRIVATE_KEY --data-file=- --project=$P
NUM=$(gcloud projects describe $P --format='value(projectNumber)')
for role in roles/run.admin roles/iam.serviceAccountUser roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding $P --member=serviceAccount:$NUM@cloudbuild.gserviceaccount.com --role=$role
done
```
Then connect the GitHub repo in Cloud Build and import the trigger from `.infra/triggers/production-deploy.yaml`.

### Forwarder functions, Scheduler
Deploy `auth-forwarder`, `firestore-forwarder`, `identity-blocking` per `cloud-functions/README.md`, grant their
service accounts `roles/run.invoker` on `show-menu-backend`, and list them in the trigger substitution
`_EVENTARC_ALLOWED_SERVICE_ACCOUNTS`. Scheduler:
```bash
URL=https://show-menu-backend-$NUM.$R.run.app
gcloud scheduler jobs create http check-expired-subscriptions --project=$P --location=$R --schedule="0 0 * * *" --time-zone=UTC \
  --uri=$URL/api/v1/subscriptions/jobs/check-expired --http-method=POST \
  --oidc-service-account-email=show-menu-scheduler@$P.iam.gserviceaccount.com --oidc-token-audience=$URL
```

## Runtime configuration
| Variable | Source |
|---|---|
| `GCP_PROJECT_ID`, `GCP_CLOUD_RUN_SERVICE_URL`, `EVENTARC_OIDC_AUDIENCE`, `SCHEDULER_OIDC_AUDIENCE`, `LIQPAY_CALLBACK_URL` | derived in `cloudbuild.yaml` from the deterministic URL |
| `EVENTARC_ALLOWED_SERVICE_ACCOUNTS`, `SCHEDULER_ALLOWED_SERVICE_ACCOUNTS`, `LIQPAY_RESULT_URL` | trigger substitutions |
| `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY` | Secret Manager |
| `BUILD_BRANCH_NAME`, `BUILD_SHORT_SHA` | Cloud Build built-ins |

An audience that differs from the URL callers use fails with a silent 401.

## Caveat
Until S17 cutover, the Node `functions` triggers (invoice/checkout) still run and would double-fire alongside the Vapor handlers.
