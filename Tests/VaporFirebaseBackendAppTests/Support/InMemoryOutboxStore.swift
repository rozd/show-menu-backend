import Foundation
@testable import VaporFirebaseBackendApp

/// In-memory ``OutboxStore`` test double mirroring the Firestore binding's
/// semantics (pending = due + ordered, idempotent mark, TTL prune) without
/// Firestore. Captures `appended` for write-side assertions and supports
/// `failAppend` fault injection for atomicity/rollback tests.
actor InMemoryOutboxStore: OutboxStore {

    private(set) var messages: [UUID: OutboxMessage] = [:]
    private(set) var appended: [OutboxMessage] = []
    private var failAppend = false

    init() {}

    enum Failure: Error, Sendable { case injectedAppendFailure }

    // MARK: - Write side

    func append(_ message: OutboxMessage) async throws {
        if failAppend {
            throw Failure.injectedAppendFailure
        }
        messages[message.id] = message
        appended.append(message)
    }

    // MARK: - Relay side

    func pending(limit: Int, now: Date) async throws -> [OutboxMessage] {
        let due: [OutboxMessage] = messages.values.filter { message in
            message.status == .pending && message.availableAt <= now
        }
        let ordered: [OutboxMessage] = due.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.sequence < rhs.sequence
        }
        return Array(ordered.prefix(limit))
    }

    func markPublished(id: UUID, at: Date) async throws {
        guard var message = messages[id] else { return }
        message.status = .published
        message.publishedAt = at
        message.lastError = nil
        messages[id] = message
    }

    func recordFailure(id: UUID, attempts: Int, availableAt: Date, error: String) async throws {
        guard var message = messages[id] else { return }
        message.attempts = attempts
        message.availableAt = availableAt
        message.lastError = error
        messages[id] = message
    }

    @discardableResult
    func deletePublished(publishedBefore cutoff: Date, limit: Int) async throws -> Int {
        let prunable: [OutboxMessage] = messages.values.filter { message in
            guard message.status == .published, let publishedAt = message.publishedAt else { return false }
            return publishedAt < cutoff
        }
        let removed = Array(prunable.prefix(limit))
        for message in removed {
            messages.removeValue(forKey: message.id)
        }
        return removed.count
    }

    // MARK: - Test helpers

    func seed(_ message: OutboxMessage) {
        messages[message.id] = message
    }

    func setFailAppend(_ value: Bool) {
        failAppend = value
    }

    func get(_ id: UUID) -> OutboxMessage? {
        messages[id]
    }
}
