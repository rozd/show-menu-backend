//
//  InboxStore.swift
//  ShowMenuBackend
//
//  The consumer-side de-duplication store contract — split into read and write phases.
//

/// Builds an ``InboxStore`` bound to a given `UnitOfWorkContext` (and thus
/// the same transaction the handler's work uses) — mirroring how a repository
/// resolves its data source from `ctx.transaction`.
typealias InboxStoreFactory = @Sendable (_ ctx: any UnitOfWorkContext) -> any InboxStore

/// Persists inbox records (processed-event markers) and enforces the
/// consumer-side de-duplication protocol.
///
/// **Why two methods instead of one `reserve+run+complete`:** the store must
/// enlist in the *same* transaction as the handler's writes (so the marker and
/// the work commit or roll back atomically) — and a single interleaved call
/// would have to read *after* the work has already written. Many document stores
/// forbid exactly that (a transaction buffers its writes and rejects a
/// subsequent read), so the contract is deliberately split into a read phase and
/// a write phase, keeping it bindable on the strictest store rather than only
/// the most permissive one. The caller therefore drives:
///
/// ```text
///   reserve(...)            // READ phase — runs before any write
///     → .proceed(ticket)
///           run the wrapped handler         // its own reads, then writes
///           complete(ticket:)               // WRITE phase — runs last
///     → .alreadyProcessed               // silent return, no work
/// ```
///
/// Implementations bind these to a transaction supplied at construction (e.g.
/// `FirestoreInboxStore` over `ctx.transaction`). The in-flight guard for
/// the *new-event* race is a transactional `create` with a uniqueness
/// precondition, enforced atomically at commit.
protocol InboxStore: Sendable {

    /// Read phase: probe the record identified by `id`.
    ///
    /// Must be called **before** any transactional write. Returns how the caller
    /// should proceed (proceed / already-processed). Expired records are treated
    /// as an empty slot.
    func reserve(id: String) async throws -> InboxReservation

    /// Write phase: persist the processed record for `ticket`.
    ///
    /// Must be called **after** the handler's own writes are buffered, as the
    /// last write in the transaction. Uses a transactional `create` (uniqueness
    /// precondition) for an empty slot, or an overwrite when the ticket marks
    /// the slot as expired.
    func complete(ticket: InboxTicket) async throws
}
