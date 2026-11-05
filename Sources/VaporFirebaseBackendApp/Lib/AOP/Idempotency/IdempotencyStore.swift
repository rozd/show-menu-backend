//
//  IdempotencyStore.swift
//  VaporFirebaseBackendApp
//
//  The de-duplication store contract — split into a read phase and a write phase.
//

/// Builds an ``IdempotencyStore`` bound to a given `UnitOfWorkContext` (and thus
/// the same transaction the command's work uses) — mirroring how a repository
/// resolves its data source from `ctx.transaction`.
typealias IdempotencyStoreFactory = @Sendable (_ ctx: any UnitOfWorkContext) -> any IdempotencyStore

/// Persists idempotency records and enforces the de-duplication protocol.
///
/// **Why two methods instead of one `reserve+run+store`:** the store must enlist
/// in the *same* transaction as the command's writes (so the record and the work
/// commit or roll back atomically). The production binding is Firestore, whose
/// transactions forbid reads after writes — so the probe (read) and the persist
/// (write) cannot be a single interleaved call. The decorator therefore drives:
///
/// ```text
///   reserve(...)        // READ phase — runs before any write
///     → .replay         // return the stored response, skip the work
///     → .inProgress     // reject (concurrent duplicate)
///     → .mismatch       // reject (same key, different body)
///     → .proceed(ticket)
///           run the wrapped handler            // its own reads, then writes
///           complete(ticket:response:)          // WRITE phase — runs last
/// ```
///
/// Implementations bind these to a transaction supplied at construction (e.g.
/// `FirestoreIdempotencyStore` over `ctx.transaction`). The in-flight guard for
/// the *new-key* race is a transactional `create` with a uniqueness precondition,
/// enforced atomically at commit.
protocol IdempotencyStore: Sendable {

    /// Read phase: probe the slot identified by `id`.
    ///
    /// Must be called **before** any transactional write. Returns how the caller
    /// should proceed (replay / reject / run-the-work). Expired records are
    /// treated as an empty slot.
    func reserve(
        id: String,
        fingerprint: RequestFingerprint
    ) async throws -> IdempotencyReservation

    /// Write phase: persist the completed record (status + response) for `ticket`.
    ///
    /// Must be called **after** the command's own writes are buffered, as the last
    /// write in the transaction. Uses a transactional `create` (uniqueness
    /// precondition) for an empty slot, or an overwrite when the ticket marks the
    /// slot as expired.
    func complete(
        ticket: IdempotencyTicket,
        response: StoredResponse
    ) async throws
}
