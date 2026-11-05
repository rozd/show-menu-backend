import Foundation
@testable import VaporFirebaseBackendApp

/// ``InboxStore`` test double mirroring the store binding's read-phase /
/// write-phase contract — without a transaction.
///
/// Writes are applied immediately (not buffered), so state persists across calls
/// within a test: ideal for duplicate / expiry / TTL behaviour. The transactional
/// commit-and-rollback semantics are exercised separately by the atomicity
/// test's purpose-built transactional double.
actor StubInboxStore: InboxStore {

    struct Entry: Sendable {
        var processedAt: Date
        var expiresAt: Date
    }

    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    /// Captured `complete` calls, for asserting the work-then-store path.
    private(set) var completedIds: [String] = []

    init(ttl: TimeInterval = 7 * 24 * 60 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    // MARK: InboxStore

    func reserve(id: String) async throws -> InboxReservation {
        guard let entry = store[id] else {
            return .proceed(InboxTicket(id: id, overwriteExpired: false))
        }
        if entry.expiresAt <= now() {
            return .proceed(InboxTicket(id: id, overwriteExpired: true))
        }
        return .alreadyProcessed
    }

    func complete(ticket: InboxTicket) async throws {
        store[ticket.id] = Entry(
            processedAt: now(),
            expiresAt: now().addingTimeInterval(ttl)
        )
        completedIds.append(ticket.id)
    }

    // MARK: Test seams

    /// Seed a processed record (e.g. left by a prior call). `expiresAt` defaults
    /// to far in the future; pass a past date to simulate an expired record.
    func seedProcessed(id: String, expiresAt: Date = Date.distantFuture) {
        store[id] = Entry(processedAt: now(), expiresAt: expiresAt)
    }

    func entry(id: String) -> Entry? { store[id] }
    var count: Int { store.count }
}
