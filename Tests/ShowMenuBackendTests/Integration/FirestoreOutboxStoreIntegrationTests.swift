import Foundation
import Testing
import Logging
import FirestoreAPI
import GRPCNIOTransportHTTP2
@testable import ShowMenuBackend

/// Emulator-backed proof of the property the whole pattern rests on: an outbox
/// `append` performed *inside* a Firestore transaction shares that transaction's
/// fate — it persists iff the transaction commits, and vanishes on rollback.
///
/// Skipped unless the Firestore emulator is running (`FIRESTORE_EMULATOR_HOST`
/// and `GCP_PROJECT_ID` set); see `EmulatorFirestoreHelper`.
@Suite("Outbox — Firestore integration")
struct FirestoreOutboxStoreIntegrationTests {

    private func makeEvent(_ value: String) -> some IntegrationEvent {
        struct E: IntegrationEvent {
            static let kind = "test.outbox.integration"
            let id: UUID
            let metadata: IntegrationEventMetadata
            let value: String
        }
        return E(id: UUID(), metadata: IntegrationEventMetadata(origin: "Test"), value: value)
    }

    @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
    func append_persistsWhenTransactionCommits() async throws {
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let logger = EmulatorFirestoreHelper.makeLogger()
        let collection = "outbox_test_\(EmulatorFirestoreHelper.uniqueId())"
        let coder = JSONIntegrationEventCoder()
        let event = makeEvent("committed")

        // Record inside a committing transaction. The explicit `Bool` binding
        // selects the non-optional `runInTransaction` overload.
        let committed: Bool = try await firestore.runInTransaction { transaction in
            let store = FirestoreOutboxStore(transaction: transaction, collection: collection, logger: logger)
            let message = try OutboxMessage.pending(from: event, sequence: 0, at: .now, coder: coder)
            try await store.append(message)
            return true
        }
        #expect(committed)

        // The relay-side (direct) store sees the committed row.
        let direct = FirestoreOutboxStore(
            transaction: .direct(firestore: firestore), collection: collection, logger: logger
        )
        let pending = try await direct.pending(limit: 100, now: Date.now.addingTimeInterval(60))
        #expect(pending.contains { $0.id == event.id })
    }

    @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
    func append_vanishesWhenTransactionRollsBack() async throws {
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let logger = EmulatorFirestoreHelper.makeLogger()
        let collection = "outbox_test_\(EmulatorFirestoreHelper.uniqueId())"
        let coder = JSONIntegrationEventCoder()
        let event = makeEvent("rolled-back")

        struct Boom: Error {}

        // Record, then throw to abort the transaction.
        await #expect(throws: Boom.self) {
            let _: Bool = try await firestore.runInTransaction { transaction in
                let store = FirestoreOutboxStore(transaction: transaction, collection: collection, logger: logger)
                let message = try OutboxMessage.pending(from: event, sequence: 0, at: .now, coder: coder)
                try await store.append(message)
                throw Boom()
            }
        }

        // Nothing committed ⇒ no orphaned outbox row.
        let direct = FirestoreOutboxStore(
            transaction: .direct(firestore: firestore), collection: collection, logger: logger
        )
        let pending = try await direct.pending(limit: 100, now: Date.now.addingTimeInterval(60))
        #expect(pending.isEmpty)
    }

    @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
    func markPublished_andCleanup_roundTrip() async throws {
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let logger = EmulatorFirestoreHelper.makeLogger()
        let collection = "outbox_test_\(EmulatorFirestoreHelper.uniqueId())"
        let coder = JSONIntegrationEventCoder()
        let event = makeEvent("publish-me")

        let direct = FirestoreOutboxStore(
            transaction: .direct(firestore: firestore), collection: collection, logger: logger
        )

        // Seed directly, mark published in the past, then prune.
        let message = try OutboxMessage.pending(from: event, sequence: 0, at: .now, coder: coder)
        try await direct.append(message)
        try await direct.markPublished(id: event.id, at: Date.now.addingTimeInterval(-10_000))

        // No longer pending.
        let stillPending = try await direct.pending(limit: 100, now: Date.now.addingTimeInterval(60))
        #expect(!stillPending.contains { $0.id == event.id })

        // Pruned by TTL cleanup.
        let deleted = try await direct.deletePublished(publishedBefore: .now, limit: 100)
        #expect(deleted >= 1)
    }
}
