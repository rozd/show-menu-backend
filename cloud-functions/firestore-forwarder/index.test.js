"use strict";

// Unit tests for the payload flattener and the CloudEvents envelope.
// Zero dependencies: Node's built-in `node:test`. Run with `node --test`.

const test = require("node:test");
const assert = require("node:assert/strict");

const { _internal: fn } = require("./index.js");

const DB = "projects/show-menu-dev/databases/(default)/documents";

/** A gen-1 `document.create` payload for an account, as the runtime delivers it. */
function accountEvent(fields = {}) {
  return {
    oldValue: {},
    updateMask: {},
    value: {
      name: `${DB}/accounts/acc-1`,
      fields: {
        name: { stringValue: "Cafe" },
        creator: { stringValue: "u-1" },
        createdAt: { timestampValue: "2026-11-05T10:00:00.123456Z" },
        ...fields,
      },
      createTime: "2026-11-05T10:00:00.123456Z",
      updateTime: "2026-11-05T10:00:00.123456Z",
    },
  };
}

const context = (over = {}) => ({
  eventId: "evt-1",
  timestamp: "2026-11-05T10:00:00.456Z",
  resource: { service: "firestore.googleapis.com", name: `${DB}/accounts/acc-1`, type: "firestore.googleapis.com/Document" },
  ...over,
});

// === flattenValue =============================================================

test("scalars", () => {
  assert.equal(fn.flattenValue({ stringValue: "a" }), "a");
  assert.equal(fn.flattenValue({ stringValue: "" }), "");
  assert.equal(fn.flattenValue({ booleanValue: false }), false);
  assert.equal(fn.flattenValue({ doubleValue: 1.5 }), 1.5);
  assert.equal(fn.flattenValue({ nullValue: null }), null);
  assert.equal(fn.flattenValue({ nullValue: "NULL_VALUE" }), null);
});

test("integerValue arrives as a string and becomes a number when safe", () => {
  assert.equal(fn.flattenValue({ integerValue: "42" }), 42);
  assert.equal(fn.flattenValue({ integerValue: "-7" }), -7);
  assert.equal(fn.flattenValue({ integerValue: "9223372036854775807" }), "9223372036854775807");
});

test("timestampValue becomes a UTC ISO string with millisecond precision", () => {
  assert.equal(
    fn.flattenValue({ timestampValue: "2026-11-05T10:00:00.123456Z" }),
    "2026-11-05T10:00:00.123Z",
  );
  assert.equal(
    fn.flattenValue({ timestampValue: "2026-11-05T12:00:00+02:00" }),
    "2026-11-05T10:00:00.000Z",
  );
  assert.equal(fn.flattenValue({ timestampValue: "garbage" }), "garbage");
});

test("maps and arrays nest, absent containers are empty", () => {
  assert.deepEqual(
    fn.flattenValue({
      mapValue: {
        fields: {
          a: { integerValue: "1" },
          list: { arrayValue: { values: [{ stringValue: "x" }, { mapValue: { fields: { k: { booleanValue: true } } } }] } },
        },
      },
    }),
    { a: 1, list: ["x", { k: true }] },
  );
  assert.deepEqual(fn.flattenValue({ mapValue: {} }), {});
  assert.deepEqual(fn.flattenValue({ arrayValue: {} }), []);
});

test("references, geo points, bytes", () => {
  assert.equal(fn.flattenValue({ referenceValue: `${DB}/users/u-1` }), "users/u-1");
  assert.deepEqual(fn.flattenValue({ geoPointValue: { latitude: 50.4, longitude: 30.5 } }), {
    latitude: 50.4,
    longitude: 30.5,
  });
  assert.equal(fn.flattenValue({ bytesValue: "AQID" }), "AQID");
});

test("unknown or malformed values flatten to null", () => {
  assert.equal(fn.flattenValue({}), null);
  assert.equal(fn.flattenValue(null), null);
  assert.equal(fn.flattenValue("raw"), null);
});

// === documentPath / body ======================================================

test("path comes from context.resource (object or string) or the document name", () => {
  assert.equal(fn.documentPath(accountEvent(), context()), "accounts/acc-1");
  assert.equal(fn.documentPath(accountEvent(), context({ resource: `${DB}/accounts/acc-9` })), "accounts/acc-9");
  assert.equal(fn.documentPath(accountEvent(), {}), "accounts/acc-1");
  assert.equal(fn.documentPath({}, {}), "");
});

test("body is {path, documentId, data} with flattened fields", () => {
  assert.deepEqual(fn.mapEventToBody(accountEvent(), context()), {
    path: "accounts/acc-1",
    documentId: "acc-1",
    data: { name: "Cafe", creator: "u-1", createdAt: "2026-11-05T10:00:00.123Z" },
  });
});

test("a document without fields yields empty data", () => {
  const event = { value: { name: `${DB}/accounts/acc-1` } };
  assert.deepEqual(fn.mapEventToBody(event, context()).data, {});
});

// === forwardEvent =============================================================

function capture() {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 200, text: async () => "" };
  };
  return { calls, fetchImpl };
}

test("envelope: CloudEvents binary-mode headers, stable ce-id, OIDC bearer", async () => {
  const { calls, fetchImpl } = capture();
  await fn.forwardEvent(accountEvent(), context(), fn.FIRESTORE_CREATED_TYPE, {
    backendUrl: "https://backend.run.app",
    projectId: "show-menu-dev",
    fetchImpl,
    getIdToken: async (aud) => `token-for-${aud}`,
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://backend.run.app");
  assert.equal(calls[0].init.method, "POST");
  assert.deepEqual(calls[0].init.headers, {
    "Content-Type": "application/json",
    "ce-specversion": "1.0",
    "ce-type": "google.cloud.firestore.document.v1.created",
    "ce-source": "//firestore.googleapis.com/projects/show-menu-dev/databases/(default)",
    "ce-id": "evt-1",
    "ce-time": "2026-11-05T10:00:00.456Z",
    "ce-subject": "documents/accounts/acc-1",
    Authorization: "Bearer token-for-https://backend.run.app",
  });
  assert.equal(JSON.parse(calls[0].init.body).documentId, "acc-1");
});

test("a redelivery carries the same ce-id and ce-source", async () => {
  const { calls, fetchImpl } = capture();
  const deps = { backendUrl: "http://b", projectId: "p", fetchImpl, getIdToken: async () => "t" };
  await fn.forwardEvent(accountEvent(), context(), fn.FIRESTORE_CREATED_TYPE, deps);
  await fn.forwardEvent(accountEvent(), context(), fn.FIRESTORE_CREATED_TYPE, deps);
  assert.equal(calls[0].init.headers["ce-id"], calls[1].init.headers["ce-id"]);
  assert.equal(calls[0].init.headers["ce-source"], calls[1].init.headers["ce-source"]);
});

test("without a metadata server the request is sent without Authorization", async () => {
  const { calls, fetchImpl } = capture();
  await fn.forwardEvent(accountEvent(), context(), fn.FIRESTORE_CREATED_TYPE, {
    backendUrl: "http://b",
    projectId: "p",
    fetchImpl,
    getIdToken: async () => {
      throw new Error("no metadata server");
    },
  });
  assert.equal(calls[0].init.headers.Authorization, undefined);
});

test("no BACKEND_URL: nothing is sent", async () => {
  const { calls, fetchImpl } = capture();
  await fn.forwardEvent(accountEvent(), context(), fn.FIRESTORE_CREATED_TYPE, {
    backendUrl: "",
    projectId: "p",
    fetchImpl,
  });
  assert.equal(calls.length, 0);
});
