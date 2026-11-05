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
| other `DomainError` | 409 | `domain_rule_violation` |
| `ConcurrencyError` | 409 | `version_conflict` |
| `AuthorizationError.denied` / `.missingPrincipal` | 403 / 401 | `forbidden` / `unauthorized` |
| `IdempotencyError` | 400 / 409 / 422 / 500 | `idempotency_key_invalid` / `request_in_progress` / `idempotency_key_reused` / `internal_error` |
| `FirestoreError` | 404 not found, 409 exists, 503 transient, else 500 | `not_found` / `conflict` / `service_unavailable` / `internal_error` |
| `DecodingError` | 400 | `bad_request` (+ field path in `details`) |
| `Abort` / any `AbortError` | its status | derived from the status (`code(for:)`) |
| anything else | 500 | `internal_error` |

Specific cases first, `AbortError` after, so typed errors keep their stable `code`. Throw typed errors from UseCases; controllers no longer need to translate them (existing controllers that `catch` and throw `Abort` keep working and are unchanged).

## Validation convention

- **Edge (shape):** Vapor `Validatable` on request DTOs (`try Payload.validate(content: req)`) for presence/format/length. Failures become 422 with per-field `details`.
- **Domain (invariants):** entities and value objects throw `ValidationError` (`LocalizedString`, `Currency`, `Price`, `Item.validate`). Never rely on edge validation for an invariant.
- DTO-level semantic rules that differ from the domain (e.g. `PriceDTO.amount > 0` while `Price` allows 0) live in the DTO's `validate()` and throw a `ValidationError`.
