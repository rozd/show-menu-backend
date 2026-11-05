import Foundation
import Testing
import Logging
@testable import FirestoreAPI
@testable import ShowMenuBackend

/// The live-transaction read cache in `FirestoreTransaction`: a repeated read of one document
/// is answered from the transaction's own snapshot, a write to that document drops the entry.
/// This is what lets a unit of work update several versioned aggregates despite the pinned
/// client forbidding reads after the first write.
@Suite("Firestore transaction read cache")
struct FirestoreTransactionReadCacheTests {

    private func makeTx(
        cachesReads: Bool = true,
        failsReadsAfterWrite: Bool = false,
        documents: [String: [String: Any]] = ["things/a": ["id": "a"], "things/b": ["id": "b"]]
    ) -> (FirestoreTransaction, CountingFirestoreTransaction) {
        let fake = CountingFirestoreTransaction(documents: documents, failsReadsAfterWrite: failsReadsAfterWrite)
        return (.counting(fake, cachesReads: cachesReads), fake)
    }

    // MARK: Caching

    @Test("two reads of one path hit the wrapped transaction once")
    func cachesRepeatedRead() async throws {
        let (tx, fake) = makeTx()
        let ref = tx.collection("things").document("a")

        let first = try await tx.get(documentReference: ref)
        let second = try await tx.get(documentReference: ref)

        #expect(first.exists && second.exists)
        #expect(fake.readCount("things/a") == 1)
    }

    @Test("different paths are cached independently")
    func cachesPerPath() async throws {
        let (tx, fake) = makeTx()
        let a = tx.collection("things").document("a")
        let b = tx.collection("things").document("b")

        _ = try await tx.get(documentReference: a)
        _ = try await tx.get(documentReference: b)
        _ = try await tx.get(documentReference: a)
        _ = try await tx.get(documentReference: b)

        #expect(fake.readCount("things/a") == 1)
        #expect(fake.readCount("things/b") == 1)
    }

    @Test("a missing document is cached as not existing")
    func cachesMissingDocument() async throws {
        let (tx, fake) = makeTx(documents: [:])
        let ref = tx.collection("things").document("ghost")

        let first = try await tx.get(documentReference: ref)
        let second = try await tx.get(documentReference: ref)

        #expect(!first.exists && !second.exists)
        #expect(fake.readCount("things/ghost") == 1)
    }

    @Test("a fresh wrapper starts empty (stands in for a new retry attempt)")
    func freshWrapperStartsEmpty() async throws {
        let fake = CountingFirestoreTransaction(documents: ["things/a": ["id": "a"]])
        let ref = PathReferenceProvider().collection("things").document("a")

        let attempt1 = FirestoreTransaction.counting(fake)
        _ = try await attempt1.get(documentReference: ref)
        _ = try await attempt1.get(documentReference: ref)
        #expect(fake.readCount("things/a") == 1)

        let attempt2 = FirestoreTransaction.counting(fake)
        _ = try await attempt2.get(documentReference: ref)
        _ = try await attempt2.get(documentReference: ref)
        #expect(fake.readCount("things/a") == 2)
    }

    @Test("cachesReads: false never caches")
    func noCacheWhenDisabled() async throws {
        let (tx, fake) = makeTx(cachesReads: false)
        let ref = tx.collection("things").document("a")

        _ = try await tx.get(documentReference: ref)
        _ = try await tx.get(documentReference: ref)

        #expect(fake.readCount("things/a") == 2)
    }

    @Test("the default wrapper (as .direct builds it) never caches")
    func defaultWrapperDoesNotCache() async throws {
        let fake = CountingFirestoreTransaction(documents: ["things/a": ["id": "a"]])
        // `.direct(firestore:)` uses this initializer without `cachesReads`.
        let tx = FirestoreTransaction(wrapping: fake, referenceProvider: PathReferenceProvider())
        let ref = tx.collection("things").document("a")

        _ = try await tx.get(documentReference: ref)
        _ = try await tx.get(documentReference: ref)

        #expect(fake.readCount("things/a") == 2)
    }

    // MARK: Invalidation

    private enum Write: CaseIterable, CustomTestStringConvertible {
        case create, set, setMerge, update, delete

        var testDescription: String { "\(self)" }

        func apply(_ tx: FirestoreTransaction, to ref: DocumentReference) async throws {
            switch self {
            case .create: try await tx.create(documentReference: ref, data: ["id": "a", "n": 1])
            case .set: try await tx.set(documentReference: ref, data: ["id": "a", "n": 1])
            case .setMerge: try await tx.set(documentReference: ref, data: ["n": 1], merge: true)
            case .update: try await tx.update(documentReference: ref, data: ["n": 1])
            case .delete: try await tx.delete(documentReference: ref)
            }
        }
    }

    @Test("a write drops that path's entry, other paths stay cached", arguments: Write.allCases)
    private func writeInvalidates(_ write: Write) async throws {
        let (tx, fake) = makeTx()
        let a = tx.collection("things").document("a")
        let b = tx.collection("things").document("b")
        _ = try await tx.get(documentReference: a)
        _ = try await tx.get(documentReference: b)

        try await write.apply(tx, to: a)

        _ = try await tx.get(documentReference: a)
        _ = try await tx.get(documentReference: b)
        #expect(fake.readCount("things/a") == 2)
        #expect(fake.readCount("things/b") == 1)
        #expect(fake.writtenPaths == ["things/a"])
    }

    // MARK: Versioned aggregates in one transaction

    private struct ThingModel: Codable, Sendable, VersionedModel {
        var id: String
        var name: String
        var version: Int?
    }

    private struct ThingDataSource: FirestoreDataSource {
        typealias Model = ThingModel
        let transaction: FirestoreTransaction
        let prefix = ""
        let suffix = "things"
        let logger = Logger(label: "test")
        func documentId(for model: ThingModel) -> String { model.id }
    }

    private let seeded: [String: [String: Any]] = [
        "things/a": ["id": "a", "name": "A", "version": 1],
        "things/b": ["id": "b", "name": "B", "version": 1]
    ]

    /// Fetch every aggregate first, then check-and-set update each: the second CAS re-read
    /// happens after the first write.
    private func updateBoth(_ tx: FirestoreTransaction) async throws {
        let things = ThingDataSource(transaction: tx)
        var a = try #require(try await things.fetch(byId: "a"))
        var b = try #require(try await things.fetch(byId: "b"))
        a.name = "A2"
        b.name = "B2"
        _ = try await things.update(model: a, ifMatching: Version(1))
        _ = try await things.update(model: b, ifMatching: Version(1))
    }

    @Test("two versioned aggregates update in one transaction when reads are cached")
    func updatesTwoVersionedAggregatesWithCache() async throws {
        let (tx, fake) = makeTx(failsReadsAfterWrite: true, documents: seeded)

        try await updateBoth(tx)

        #expect(fake.writtenPaths == ["things/a", "things/b"])
        #expect(fake.document("things/a")?["name"] as? String == "A2")
        #expect(fake.document("things/b")?["name"] as? String == "B2")
        // Each document was read from the server exactly once (the fetch); the CAS re-read was local.
        #expect(fake.readCount("things/a") == 1)
        #expect(fake.readCount("things/b") == 1)
    }

    @Test("the same scenario fails with a read-after-write error without the cache")
    func failsWithoutCache() async throws {
        let (tx, _) = makeTx(cachesReads: false, failsReadsAfterWrite: true, documents: seeded)

        await #expect(throws: (any Error).self) {
            try await updateBoth(tx)
        }
    }
}
