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
Prerequisite: **billing enabled** on `show-menu-dev` (Artifact Registry and Cloud Build need it).

```bash
P=show-menu-dev; R=europe-west1
gcloud services enable cloudbuild run artifactregistry secretmanager --project=$P
gcloud artifacts repositories create show-menu-backend-repo --repository-format=docker --location=$R --project=$P
gcloud iam service-accounts create show-menu-api --project=$P          # runtime identity
for role in roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding $P --member=serviceAccount:show-menu-api@$P.iam.gserviceaccount.com --role=$role
done
# Fine-grained, read-only PAT (Contents: read) on rozd/show-menu-contracts, used by Cloud Build to
# resolve the private ShowMenuContracts SwiftPM package (BuildKit secret; never in an image layer).
printf '%s' "<github PAT>" | gcloud secrets create github-contracts-token --data-file=- --project=$P
printf '%s' "<public key>"  | gcloud secrets create LIQPAY_PUBLIC_KEY  --data-file=- --project=$P
printf '%s' "<private key>" | gcloud secrets create LIQPAY_PRIVATE_KEY --data-file=- --project=$P
NUM=$(gcloud projects describe $P --format='value(projectNumber)')
for role in roles/run.admin roles/iam.serviceAccountUser roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding $P --member=serviceAccount:$NUM@cloudbuild.gserviceaccount.com --role=$role
done
# Let the build read the contracts token (secret-level grant, narrower than the project-level roles above)
gcloud secrets add-iam-policy-binding github-contracts-token --project=$P \
  --member=serviceAccount:$NUM@cloudbuild.gserviceaccount.com --role=roles/secretmanager.secretAccessor
```
`cloudbuild.yaml` exposes the secret to the build step as `GITHUB_CONTRACTS_TOKEN` (`availableSecrets`) and passes it to
`docker build --secret id=github_token,env=GITHUB_CONTRACTS_TOKEN`. Rotate it with `gcloud secrets versions add github-contracts-token`;
the build always reads `latest`. GitHub Actions uses a separate repo secret, `SHOWMENU_WORKSPACE_TOKEN`.
If the build runs as a different service account than the default one above, grant that account `roles/secretmanager.secretAccessor` instead.
Then connect the GitHub repo in Cloud Build and import the trigger from `.infra/triggers/production-deploy.yaml`.

### Database
Production requires a Postgres `DATABASE_URL` (hosting is not decided yet). Without it the app falls back to an
in-memory SQLite database, which loses all accounts and tokens on every restart and must never serve production.
Store the URL in Secret Manager and mount it on the service with `--update-secrets`; also provide the Passage signing
keys (`JWKS` or `JWKS_FILE_PATH`) the same way. `cloudbuild.yaml` does not wire either yet (see the TODO there), so wire
them before the first Postgres deploy.

The app enforces this: with `--env production` (the Dockerfile default) it fails at boot if neither `DATABASE_URL` /
`DATABASE_HOST` nor `JWKS` / `JWKS_FILE_PATH` is set, instead of falling back to SQLite or an ephemeral key.

## Runtime configuration
| Variable | Source |
|---|---|
| `LIQPAY_CALLBACK_URL` | derived in `cloudbuild.yaml` from the deterministic URL |
| `LIQPAY_RESULT_URL` | trigger substitution |
| `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY` | Secret Manager |
| `DATABASE_URL` (required in production), `JWKS` | Secret Manager (not yet wired in `cloudbuild.yaml`) |
| `BUILD_BRANCH_NAME`, `BUILD_SHORT_SHA` | Cloud Build built-ins |

Health check: `curl https://show-menu-backend-$NUM.$R.run.app/api/v1/health` returns `{"status":"ok"}` (public; the old `/health` is gone).

## Manual steps

### LiqPay merchant console
1. **Rotate the sandbox keys.** In the LiqPay merchant console issue a new public/private key pair. Then:
   ```bash
   P=show-menu-dev
   printf '%s' "<new public key>"  | gcloud secrets versions add LIQPAY_PUBLIC_KEY  --data-file=- --project=$P
   printf '%s' "<new private key>" | gcloud secrets versions add LIQPAY_PRIVATE_KEY --data-file=- --project=$P
   gcloud run services update show-menu-backend --region=europe-west1 --project=$P   # new revision picks up `latest`
   ```
   Confirm the secrets are mounted as `latest` (`gcloud run services describe show-menu-backend --region=europe-west1 --project=$P`); disable the old versions afterwards.
2. **Repoint the callback.** Set the merchant `server_url` to `https://show-menu-backend-329418335969.europe-west1.run.app/api/v1/payments/liqpay/callback` (the same value as `LIQPAY_CALLBACK_URL`). Checkout also sends it per request, so this only matters for subscription renewals LiqPay initiates.
3. **Verify.** Run one sandbox purchase from the Flutter dev build (`--dart-define=API_BASE_URL=https://show-menu-backend-329418335969.europe-west1.run.app/api`) and confirm the session reaches `success` and a subscription exists.
