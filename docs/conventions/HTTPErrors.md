# HTTP errors and DTO validation

## One envelope (D4)

Every failure — handler errors, Vapor's own 404 for unknown routes, malformed bodies — is rendered by `HTTPErrorMiddleware` (`Integration/Vapor/HTTPErrorMiddleware.swift`) as:

```json
{"error":{"code":"validation_failed","message":"…","details":[{"field":"name","message":"…"}]}}
```

`details` is optional. The middleware **replaces** Vapor's `ErrorMiddleware` (`app.useErrorEnvelope()` in `configure.swift` resets `app.middleware` before anything else is added) — never stack it on the default one. 5xx messages are always the generic `Internal server error`; the real error is logged only.

## Mapping table (`HTTPErrorMapping.map`)

| Error | Status | `code` |
|---|---|---|
| `ApplicationError.notFound` | 404 | `not_found` |
| `ApplicationError.invalidInput`, `ValidationError`, Vapor `ValidationsError` | 422 | `validation_failed` |
| other `DomainError` | 409 (provisional default) | `domain_rule_violation` |
| `DomainError & HTTPStatusHinted` | `httpStatusHint` | derived from the status |
| `ConcurrencyError` | 409 | `version_conflict` |
| `AuthorizationError.denied` / `.missingPrincipal` | 403 / 401 | `forbidden` / `unauthorized` |
| `IdempotencyError` | 400 / 409 / 422 / 500 | `idempotency_key_invalid` / `request_in_progress` / `idempotency_key_reused` / `internal_error` |
| `FirestoreError` | 404 not found, 409 exists, 503 transient, else 500 | `not_found` / `conflict` / `service_unavailable` / `internal_error` |
| `DecodingError` | 400 | `bad_request` (+ field path in `details`) |
| `ServerError` (generated server) | that of its `underlyingError`; runtime 4xx by its own status (415 `unsupported_media_type`, …) | see above |
| `Abort` / any `AbortError` | its status | derived from the status (`code(for:)`) |
| anything else | 500 | `internal_error` |

Specific cases first, `AbortError` after, so typed errors keep their stable `code`. Throw typed errors from UseCases; controllers no longer need to translate them (existing controllers that `catch` and throw `Abort` keep working and are unchanged).

## Generated server (OpenAPI) errors

HTTP routes are generated from the wire contract (see [WireContract.md](WireContract.md)), so failures arrive wrapped:

- **`ServerError` unwrap.** The generated server wraps every handler, middleware and decoding failure in `ServerError`. `HTTPErrorMapping.map` maps its `underlyingError` (recursively), so a thrown domain / `AuthorizationError` / `DecodingError` keeps its stable `code`. Controllers throw; there are no per-operation typed error cases.
- **Runtime-originated 4xx.** Errors raised inside `OpenAPIRuntime` itself (missing request body, bad parameter, unsupported content type) are not ours, so they would fall through to 500; the mapper instead uses the `ServerError`'s own status (`code(for:)`, message = its cause description). A wrong request `Content-Type` is therefore **415 `unsupported_media_type`**.
- **400 vs 422 for decoding.** A missing or ill-typed field in a generated body fails in the generated decoder: **400 `bad_request`** (`DecodingError`, field path in `details`). **422 `validation_failed`** is for semantic validation after a body decoded (DTO `validate()`, domain `ValidationError`). Do not move shape checks into the domain to get a 422.
- **Logging.** `ServerError.description` embeds the whole request including `Authorization`; log `HTTPErrorMiddleware.loggable(_:)` (operation id + underlying error) instead.
- **Access failures** come from `ContractAccessMiddleware`: 401 `unauthorized` (also for an operation missing from its table, fail closed), 403 `forbidden` (non-admin on an admin operation).

## Validation convention

- **Edge (shape):** the generated decoder enforces presence and types from the spec (400 `bad_request`). Vapor `Validatable` is no longer used for request bodies (controllers take no `Request`); format/length rules belong in the contract schema or the DTO's `validate()`. Failures from `validate()` become 422.
- **Domain (invariants):** entities and value objects throw `ValidationError` (`LocalizedString`, `Currency`, `Price`, `Feature.validate`). Never rely on edge validation for an invariant.
- DTO-level semantic rules that differ from the domain (e.g. `PriceDTO.amount > 0` while `Price` allows 0) live in the DTO's `validate()` and throw a `ValidationError`.

## DomainError statuses (convention)

The plain-`DomainError` → 409 default is **provisional**. A rule violation that is really a client-input problem (plan not active, price mismatch → 422) must either conform to `ValidationError` (422) or adopt `HTTPStatusHinted` and return an explicit `httpStatusHint`. Pick the explicit hint when the status is neither 422 nor 409. Never rely on the 409 default for new errors.

## Middleware order

`entrypoint` installs the Cloud Run trace middleware first; `useErrorEnvelope()` preserves all installed middleware, removes only Vapor's `ErrorMiddleware`, and inserts ours right after the trace middleware: trace → error envelope → everything else.
