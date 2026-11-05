import Foundation
@testable import FirestoreAPI
@testable import ShowMenuBackend

/// A `FirestoreTransactionProtocol` fake that stores documents in memory, counts every call
/// per document path and can emulate the pinned client's "reads after writes are forbidden"
/// rule. Wrap it in `FirestoreTransaction(wrapping:referenceProvider:cachesReads:)` to test the
/// wrapper's read cache without a Firestore server.
final class CountingFirestoreTransaction: FirestoreTransactionProtocol, @unchecked Sendable {

    struct ReadAfterWriteError: Error, Equatable {}

    private let lock = NSLock()
    private var documents: [String: [String: Any]]
    private var reads: [String: Int] = [:]
    private var writes: [String] = []
    private var wroteAnything = false

    /// When true, any `get` after the first buffered write throws `ReadAfterWriteError`.
    private let failsReadsAfterWrite: Bool

    init(documents: [String: [String: Any]] = [:], failsReadsAfterWrite: Bool = false) {
        self.documents = documents
        self.failsReadsAfterWrite = failsReadsAfterWrite
    }

    /// Number of `get(documentReference:)` calls that reached this fake for `path`.
    func readCount(_ path: String) -> Int { lock.withLock { reads[path, default: 0] } }

    /// Paths written, in order (`create` / `set` / `update` / `delete`).
    var writtenPaths: [String] { lock.withLock { writes } }

    func document(_ path: String) -> [String: Any]? { lock.withLock { documents[path] } }

    // MARK: FirestoreTransactionProtocol

    func get(documentReference: DocumentReference) async throws -> DocumentSnapshot {
        try lock.withLock {
            if failsReadsAfterWrite && wroteAnything { throw ReadAfterWriteError() }
            reads[documentReference.path, default: 0] += 1
            guard let data = documents[documentReference.path] else {
                return DocumentSnapshot(document: nil, documentReference: documentReference)
            }
            let document = Google_Firestore_V1_Document.with { $0.fields = DocumentData(data: data).getFields() }
            return DocumentSnapshot(document: document, documentReference: documentReference)
        }
    }

    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot {
        fatalError("CountingFirestoreTransaction.get(query:) not implemented")
    }

    func create(documentReference: DocumentReference, data: [String: Any]) async throws {
        record(documentReference.path) { $0[documentReference.path] = data }
    }

    func set(documentReference: DocumentReference, data: [String: Any]) async throws {
        record(documentReference.path) { $0[documentReference.path] = data }
    }

    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) async throws {
        record(documentReference.path) { docs in
            docs[documentReference.path] = merge
                ? (docs[documentReference.path] ?? [:]).merging(data) { _, new in new }
                : data
        }
    }

    func update(documentReference: DocumentReference, data: [String: Any]) async throws {
        record(documentReference.path) { docs in
            docs[documentReference.path] = (docs[documentReference.path] ?? [:]).merging(data) { _, new in new }
        }
    }

    func delete(documentReference: DocumentReference) async throws {
        record(documentReference.path) { $0[documentReference.path] = nil }
    }

    private func record(_ path: String, _ mutate: (inout [String: [String: Any]]) -> Void) {
        lock.withLock {
            wroteAnything = true
            writes.append(path)
            mutate(&documents)
        }
    }
}

/// Forms references purely from path strings; no server involved.
struct PathReferenceProvider: FirestoreReferenceProvider {
    private let database = Database(projectId: "test", databaseId: "(default)")

    func collection(_ collectionID: String) -> CollectionReference {
        CollectionReference(database, parentPath: nil, collectionID: collectionID)
    }

    func document(_ documentID: String) -> DocumentReference {
        collection(documentID.split(separator: "/").dropLast().joined(separator: "/"))
            .document(String(documentID.split(separator: "/").last ?? ""))
    }

    func collectionGroup(_ groupID: String) -> CollectionGroup {
        fatalError("PathReferenceProvider.collectionGroup(_:) not implemented")
    }

    func count(_ collection: CollectionReference) async throws -> Int {
        fatalError("PathReferenceProvider.count(_:) not implemented")
    }
}

extension FirestoreTransaction {
    /// A transaction wrapper over `fake`, with the live-transaction read cache switched on or off.
    static func counting(_ fake: CountingFirestoreTransaction, cachesReads: Bool = true) -> FirestoreTransaction {
        FirestoreTransaction(wrapping: fake, referenceProvider: PathReferenceProvider(), cachesReads: cachesReads)
    }
}
