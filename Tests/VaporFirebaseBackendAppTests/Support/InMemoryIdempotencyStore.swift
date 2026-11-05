import Foundation
@testable import VaporFirebaseBackendApp

/// In-memory ``IdempotencyStore`` test double mirroring the Firestore binding's
/// read-phase / write-phase contract — without Firestore or a transaction.
///
/// Writes are applied immediately (not buffered), so state persists across calls
/// within a test: ideal for replay / in-flight / mismatch / TTL behaviour. The
/// transactional commit-and-rollback semantics are exercised separately by the
/// atomicity test's purpose-built transactional double.
actor InMemoryIdempotencyStore: IdempotencyStore {

    struct Entry: Sendable {
        var fingerprint: RequestFingerprint
        var status: IdempotencyStatus
        var response: StoredResponse?
        var expiresAt: Date
    }

    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    /// Captured `complete` calls, for asserting the work-then-store path.
    private(set) var completedIds: [String] = []

    init(ttl: TimeInterval = 24 * 60 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    // MARK: IdempotencyStore

    func reserve(
        id: String,
        fingerprint: RequestFingerprint
    ) async throws -> IdempotencyReservation {
        guard let entry = store[id] else {
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: false))
        }
        if entry.expiresAt <= now() {
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: true))
        }
        guard entry.fingerprint == fingerprint else {
            return .mismatch
        }
        switch entry.status {
        case .completed:
            return .replay(entry.response ?? StoredResponse(status: 200, body: Data()))
        case .inProgress:
            return .inProgress
        }
    }

    func complete(
        ticket: IdempotencyTicket,
        response: StoredResponse
    ) async throws {
        store[ticket.id] = Entry(
            fingerprint: ticket.fingerprint,
            status: .completed,
            response: response,
            expiresAt: now().addingTimeInterval(ttl)
        )
        completedIds.append(ticket.id)
    }

    // MARK: Test seams

    /// Seed a completed record (e.g. left by a prior call). `expiresAt` defaults
    /// to far in the future; pass a past date to simulate an expired record.
    func seedCompleted(
        id: String,
        fingerprint: RequestFingerprint,
        response: StoredResponse,
        expiresAt: Date = Date.distantFuture
    ) {
        store[id] = Entry(fingerprint: fingerprint, status: .completed, response: response, expiresAt: expiresAt)
    }

    /// Seed an in-progress marker (simulating a concurrent/uncommitted attempt).
    func seedInProgress(id: String, fingerprint: RequestFingerprint) {
        store[id] = Entry(fingerprint: fingerprint, status: .inProgress, response: nil, expiresAt: Date.distantFuture)
    }

    func entry(id: String) -> Entry? { store[id] }
    var count: Int { store.count }
}
