/**
 * Minimal Firebase Auth event forwarder for Cloud Run.
 *
 * Deployed via `gcloud functions deploy` (v1, no Firebase CLI needed).
 * Receives raw auth events, formats them as CloudEvents v1.0,
 * and POSTs to the Swift backend's webhook endpoint.
 *
 * Required env vars:
 *   BACKEND_URL  — Cloud Run service URL (e.g. https://show-menu-backend-xxxxx.run.app)
 *   GCP_PROJECT  — GCP project ID (auto-set by Cloud Functions runtime as GCLOUD_PROJECT)
 */

const BACKEND_URL = process.env.BACKEND_URL;
const GCP_PROJECT = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT;

/**
 * Fetches an ID token from the GCE metadata server for service-to-service auth.
 * Only works when running on GCP (Cloud Functions, Cloud Run, etc.).
 */
async function getIdToken(audience) {
  const url = `http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${audience}`;
  const res = await fetch(url, { headers: { "Metadata-Flavor": "Google" } });
  if (!res.ok) throw new Error(`Metadata server returned ${res.status}`);
  return res.text();
}

/**
 * Maps raw auth event to AuthEventData matching the Swift backend's expected format.
 * Key mapping: photoURL (Firebase) -> photoUrl (backend)
 * Key mapping: metadata.createdAt (raw event) -> metadata.createTime (backend)
 */
function mapEventToAuthData(event) {
  return {
    uid: event.uid,
    email: event.email || null,
    displayName: event.displayName || null,
    photoUrl: event.photoURL || null,
    phoneNumber: event.phoneNumber || null,
    emailVerified: event.emailVerified ?? null,
    disabled: event.disabled ?? null,
    metadata: event.metadata
      ? { createTime: event.metadata.createdAt || event.metadata.creationTime || null }
      : null,
  };
}

/**
 * Forwards an auth event to the backend as a CloudEvents v1.0 HTTP request.
 *
 * `ce-id` MUST be stable across redeliveries: the backend derives the
 * integration event id from `ce-source` + `ce-id`, and its inbox de-duplicates
 * on that id. Background functions are delivered at-least-once, so a fresh
 * random id per invocation would let a duplicate delivery bypass the inbox.
 * `context.eventId` is the trigger's own event id, the same on every delivery
 * of one event. The random fallback is only for invocations without a context
 * (e.g. calling the handler by hand in local dev).
 */
async function forwardEvent(event, context, ceType) {
  if (!BACKEND_URL) {
    console.error("BACKEND_URL not set");
    return;
  }

  const headers = {
    "Content-Type": "application/json",
    "ce-specversion": "1.0",
    "ce-type": ceType,
    "ce-source": `//firebase.googleapis.com/projects/${GCP_PROJECT}`,
    "ce-id": context?.eventId || crypto.randomUUID(),
    "ce-time": context?.timestamp || new Date().toISOString(),
    "ce-subject": `users/${event.uid}`,
  };

  try {
    const token = await getIdToken(BACKEND_URL);
    headers["Authorization"] = `Bearer ${token}`;
  } catch {
    // Metadata server unavailable (local dev) — proceed without auth
  }

  const body = mapEventToAuthData(event);

  console.log(`Forwarding ${ceType} for user ${event.uid} to ${BACKEND_URL}`);

  const response = await fetch(BACKEND_URL, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error(`Backend returned ${response.status}: ${text}`);
  } else {
    console.log(`Event forwarded successfully for user ${event.uid}`);
  }
}

exports.onUserCreated = (event, context) =>
  forwardEvent(event, context, "google.firebase.auth.user.v1.created");

exports.onUserDeleted = (event, context) =>
  forwardEvent(event, context, "google.firebase.auth.user.v1.deleted");
