/**
 * Minimal Firestore event forwarder for Cloud Run.
 *
 * Deployed via `gcloud functions deploy` (gen-1, no Firebase CLI needed).
 * Receives a raw Firestore `document.create` event, formats it as a
 * CloudEvents v1.0 request and POSTs it to the Swift backend's webhook (`POST /`).
 * Same envelope style as `../auth-forwarder`.
 *
 * Required env vars:
 *   BACKEND_URL  — Cloud Run service URL (e.g. https://show-menu-backend-xxxxx.run.app)
 *   GCP_PROJECT  — GCP project ID (auto-set by the runtime as GCLOUD_PROJECT)
 */

const BACKEND_URL = process.env.BACKEND_URL;
const GCP_PROJECT = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT;

const FIRESTORE_CREATED_TYPE = "google.cloud.firestore.document.v1.created";

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
 * Converts one typed Firestore value (the REST/`Value` encoding a gen-1 trigger
 * delivers in `value.fields`) to plain JSON:
 *
 *   stringValue / booleanValue / doubleValue → as is
 *   integerValue  → number (the wire form is a decimal *string*; kept as a string
 *                   only when it does not fit a double exactly)
 *   timestampValue → ISO 8601 string (UTC, millisecond precision)
 *   nullValue → null
 *   mapValue {fields} → object        arrayValue {values} → array
 *   referenceValue → the document path string, without the
 *                    `projects/{p}/databases/{d}/documents/` prefix
 *   geoPointValue → {latitude, longitude}
 *   bytesValue → base64 string (as delivered)
 */
function flattenValue(value) {
  if (value === null || typeof value !== "object") return null;
  if ("stringValue" in value) return value.stringValue;
  if ("booleanValue" in value) return value.booleanValue;
  if ("integerValue" in value) {
    const n = Number(value.integerValue);
    return Number.isSafeInteger(n) ? n : String(value.integerValue);
  }
  if ("doubleValue" in value) return Number(value.doubleValue);
  if ("timestampValue" in value) {
    const date = new Date(value.timestampValue);
    return Number.isNaN(date.getTime()) ? value.timestampValue : date.toISOString();
  }
  if ("nullValue" in value) return null;
  if ("mapValue" in value) return flattenFields(value.mapValue?.fields);
  if ("arrayValue" in value) return (value.arrayValue?.values || []).map(flattenValue);
  if ("referenceValue" in value) {
    const ref = String(value.referenceValue);
    const marker = "/documents/";
    const at = ref.indexOf(marker);
    return at >= 0 ? ref.slice(at + marker.length) : ref;
  }
  if ("geoPointValue" in value) {
    return {
      latitude: value.geoPointValue.latitude ?? 0,
      longitude: value.geoPointValue.longitude ?? 0,
    };
  }
  if ("bytesValue" in value) return value.bytesValue;
  return null;
}

/** Flattens a `{ name: typedValue }` map (absent → `{}`). */
function flattenFields(fields) {
  const out = {};
  for (const [key, value] of Object.entries(fields || {})) {
    out[key] = flattenValue(value);
  }
  return out;
}

/**
 * Document path relative to the database (`accounts/abc`), from the trigger's
 * resource (a string, or `{ name }` on newer runtimes) or the document's own name.
 */
function documentPath(event, context) {
  const resource = context?.resource;
  const name =
    (typeof resource === "string" ? resource : resource?.name) ||
    event?.value?.name ||
    "";
  const marker = "/documents/";
  const at = name.indexOf(marker);
  return at >= 0 ? name.slice(at + marker.length) : "";
}

/**
 * The webhook body: `{ path, documentId, data }`, `data` flattened to plain JSON.
 */
function mapEventToBody(event, context) {
  const path = documentPath(event, context);
  return {
    path,
    documentId: path.split("/").pop() || "",
    data: flattenFields(event?.value?.fields),
  };
}

/**
 * Forwards a Firestore event to the backend as a CloudEvents v1.0 HTTP request.
 *
 * `ce-id` MUST be stable across redeliveries: the backend derives the
 * integration event id from `ce-source` + `ce-id` and its inbox de-duplicates on
 * it. `context.eventId` is the trigger's own event id, the same on every
 * delivery of one event. The random fallback is only for invocations without a
 * context (calling the handler by hand).
 */
async function forwardEvent(event, context, ceType, deps = {}) {
  const backendUrl = deps.backendUrl ?? BACKEND_URL;
  const projectId = deps.projectId ?? GCP_PROJECT;
  const fetchImpl = deps.fetchImpl ?? fetch;
  const idToken = deps.getIdToken ?? getIdToken;

  if (!backendUrl) {
    console.error("BACKEND_URL not set");
    return;
  }

  const body = mapEventToBody(event, context);

  const headers = {
    "Content-Type": "application/json",
    "ce-specversion": "1.0",
    "ce-type": ceType,
    "ce-source": `//firestore.googleapis.com/projects/${projectId}/databases/(default)`,
    "ce-id": context?.eventId || crypto.randomUUID(),
    "ce-time": context?.timestamp || new Date().toISOString(),
    "ce-subject": `documents/${body.path}`,
  };

  try {
    const token = await idToken(backendUrl);
    headers["Authorization"] = `Bearer ${token}`;
  } catch {
    // Metadata server unavailable (local dev) — proceed without auth
  }

  console.log(`Forwarding ${ceType} for ${body.path} to ${backendUrl}`);

  const response = await fetchImpl(backendUrl, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error(`Backend returned ${response.status}: ${text}`);
  } else {
    console.log(`Event forwarded successfully for ${body.path}`);
  }
}

exports.onAccountCreated = (event, context) =>
  forwardEvent(event, context, FIRESTORE_CREATED_TYPE);

// Exported for tests.
exports._internal = {
  flattenValue,
  flattenFields,
  documentPath,
  mapEventToBody,
  forwardEvent,
  FIRESTORE_CREATED_TYPE,
};
