//
//  OutboxStore.swift
//  VaporFirebaseBackendApp
//
//  Persistence boundary for the transactional outbox.
//

import Foundation

/// Persistence boundary for the transactional outbox, with two sides.
///
/// **Write side** (`append`) is called *inside* a Unit of Work and MUST enlist in
/// that work's transaction — the row commits atomically with the state change, or
/// not at all. A concrete store binds to the active transaction exactly as a
/// ``Repository`` binds its ``DataSource`` (see `FirestoreOutboxStore`); it must
/// never open its own connection or transaction.
///
/// **Relay side** (`pending` / `markPublished` / `recordFailure` /
/// `deletePublished`) runs *outside* any command transaction, draining and
/// pruning the outbox from a background worker.
protocol OutboxStore: Sendable {

    // MARK: - Write side (enlists in the caller's transaction)

    /// Append a message within the caller's active transaction.
    ///
    /// A failure here MUST propagate so the surrounding transaction aborts —
    /// never swallow it, or atomicity (the whole point of the outbox) is lost.
    func append(_ message: OutboxMessage) async throws

    // MARK: - Relay side (non-transactional)

    /// Fetch up to `limit` messages eligible for publication — `pending` and
    /// *due* (`availableAt <= now`) — in best-effort FIFO order (`createdAt`,
    /// then `sequence`).
    func pending(limit: Int, now: Date) async throws -> [OutboxMessage]

    /// Mark a message published. Idempotent: a missing or already-published row
    /// is treated as success.
    func markPublished(id: UUID, at: Date) async throws

    /// Record a failed publish attempt, advancing `attempts` and `availableAt`
    /// (backoff) and storing `error`, leaving the row `pending` for retry.
    func recordFailure(id: UUID, attempts: Int, availableAt: Date, error: String) async throws

    /// Delete published messages whose `publishedAt` precedes `cutoff` (TTL
    /// cleanup), up to `limit`. Returns the number removed.
    @discardableResult
    func deletePublished(publishedBefore cutoff: Date, limit: Int) async throws -> Int
}
