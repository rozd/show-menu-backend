//
//  IdempotencyError.swift
//  VaporFirebaseBackendApp
//
//  Errors raised by the idempotency subsystem.
//

/// Errors surfaced by the idempotency layer. Each maps to a distinct edge
/// status; the mapping itself lives at the HTTP boundary (see the controller),
/// keeping these primitives transport-agnostic.
enum IdempotencyError: Error, Equatable {

    /// The `Idempotency-Key` header was empty or exceeded the length bound.
    /// Edge → `400 Bad Request`.
    case malformedKey(String)

    /// A duplicate request arrived while the original is still in flight (an
    /// in-progress record occupies the slot, or the de-duplication `create`
    /// lost the commit race after the runner's retries). The work is *not* run
    /// a second time. Edge → `409 Conflict` (the client may retry later).
    case requestInProgress(key: String)

    /// The same key was reused with a different request payload — client misuse
    /// of the token. Edge → `422 Unprocessable Entity`.
    case fingerprintMismatch(key: String)

    /// A stored idempotency record could not be decoded — a `completed` record
    /// whose persisted response body is missing, or present but not valid base64.
    /// Either is corrupt server-side state (the write path always stores a valid
    /// body), not client misuse. Edge → `500 Internal Server Error`.
    case corruptRecord(id: String)
}
