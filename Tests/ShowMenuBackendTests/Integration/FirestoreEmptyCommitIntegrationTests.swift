import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

/// Regression for the pinned FirebaseAPI `Transaction.commit()` throwing
/// `commitFailed` on a commit with zero writes (the emulator answers `{}`).
/// Without the no-op write in `runInTransaction`, each of these ran the body
/// 5x and then threw.
///
/// Skipped unless the Firestore emulator is running; see `EmulatorFirestoreHelper`.
@Suite("Write-less transactions — Firestore integration")
struct FirestoreEmptyCommitIntegrationTests {

    /// Counts body executions, to prove the write-less body is not retried.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
    func readOnlyBody_commitsOnceWithoutRetry() async throws {
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let runs = Counter()

        let value: Int = try await firestore.runInTransaction { transaction in
            runs.increment()
            let missing = try await transaction.get(
                documentReference: transaction.document("empty_commit_test/\(EmulatorFirestoreHelper.uniqueId())")
            )
            #expect(!missing.exists)
            return 42
        }

        #expect(value == 42)
        #expect(runs.count == 1)
    }

    @Test(.enabled(if: EmulatorFirestoreHelper.isAvailable))
    func inboxDuplicate_isSkippedWithoutError() async throws {
        let firestore = try EmulatorFirestoreHelper.makeFirestore()
        let logger = EmulatorFirestoreHelper.makeLogger()
        let collection = "inbox_test_\(EmulatorFirestoreHelper.uniqueId())"
        let recordId = InboxRecordId.derive(consumer: "Test.Consumer", eventId: UUID())

        func deliver(_ runs: Counter) async throws -> Bool {
            try await firestore.runInTransaction { transaction in
                runs.increment()
                let store = FirestoreInboxStore(
                    transaction: transaction, collectionPath: collection, ttl: 3600, logger: logger
                )
                switch try await store.reserve(id: recordId) {
                case .alreadyProcessed:
                    return false
                case .proceed(let ticket):
                    try await store.complete(ticket: ticket)
                    return true
                }
            }
        }

        let first = Counter()
        let second = Counter()
        #expect(try await deliver(first) == true)
        // Redelivery: reserve → alreadyProcessed → zero writes → must still commit.
        #expect(try await deliver(second) == false)
        #expect(second.count == 1)
    }
}
