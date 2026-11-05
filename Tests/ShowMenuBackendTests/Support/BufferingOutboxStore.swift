import Foundation
@testable import ShowMenuBackend

/// An ``OutboxStore`` test double that models Firestore's buffered-write
/// transaction semantics: `append` buffers the row, and it only becomes visible
/// in the backing `target` store when `commit()` is called — `rollback()`
/// discards it. This lets `StubUnitOfWork` mirror the real
/// `FirestoreTransactionUnitOfWork`, where recorded outbox rows commit with the
/// transaction or vanish on failure.
///
/// Relay-side reads/writes delegate straight to the (committed) `target`.
actor BufferingOutboxStore: OutboxStore {

    private let target: InMemoryOutboxStore
    private var buffer: [OutboxMessage] = []

    init(target: InMemoryOutboxStore) {
        self.target = target
    }

    // MARK: Write side (buffered until commit)

    func append(_ message: OutboxMessage) async throws {
        buffer.append(message)
    }

    func commit() async throws {
        for message in buffer {
            // Surface a commit failure (e.g. injected `failAppend`) instead of
            // silently dropping rows — that would let `StubUnitOfWork.execute`
            // proceed as if the transaction committed and mask atomicity bugs.
            try await target.append(message)
        }
        buffer.removeAll()
    }

    func rollback() {
        buffer.removeAll()
    }

    // MARK: Relay side (delegates to the committed store)

    func pending(limit: Int, now: Date) async throws -> [OutboxMessage] {
        try await target.pending(limit: limit, now: now)
    }

    func markPublished(id: UUID, at: Date) async throws {
        try await target.markPublished(id: id, at: at)
    }

    func recordFailure(id: UUID, attempts: Int, availableAt: Date, error: String) async throws {
        try await target.recordFailure(id: id, attempts: attempts, availableAt: availableAt, error: error)
    }

    @discardableResult
    func deletePublished(publishedBefore cutoff: Date, limit: Int) async throws -> Int {
        try await target.deletePublished(publishedBefore: cutoff, limit: limit)
    }
}
