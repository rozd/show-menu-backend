import Foundation
import GRPCCore
import FirestoreAPI

// MARK: - Transaction Type Erasure

/// Captures the transport-independent API surface of `Transaction<Transport>`.
/// All methods take/return non-generic types, making this safe to existential-box.
protocol FirestoreTransactionProtocol {
    func get(documentReference: DocumentReference) async throws -> DocumentSnapshot
    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot
    func create(documentReference: DocumentReference, data: [String: Any]) async throws
    func set(documentReference: DocumentReference, data: [String: Any]) async throws
    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) async throws
    func update(documentReference: DocumentReference, data: [String: Any]) async throws
    func delete(documentReference: DocumentReference) async throws
}

extension Transaction: FirestoreTransactionProtocol {}

// MARK: - Reference Provider Type Erasure

/// Captures the reference-forming API of `Firestore<Transport>` — and its
/// non-transactional aggregation reads (`count`) — without exposing
/// data-modification or connection-management methods.
protocol FirestoreReferenceProvider: Sendable {
    func collection(_ collectionID: String) -> CollectionReference
    func document(_ documentID: String) -> DocumentReference
    func collectionGroup(_ groupID: String) -> CollectionGroup
    func count(_ collection: CollectionReference) async throws -> Int
}

extension Firestore: FirestoreReferenceProvider {
    func count(_ collection: CollectionReference) async throws -> Int {
        try await collection.count(firestore: self)
    }
}

// MARK: - Non-Generic Wrapper

/// Counts the writes buffered through one `FirestoreTransaction` wrapper.
///
/// The pinned FirebaseAPI `Transaction.commit()` throws `commitFailed` when the
/// commit response has no `commitTime`, which the Firestore emulator omits for a
/// commit with zero writes. `runInTransaction` consults this to repair that case.
final class FirestoreWriteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordWrite() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var writeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

struct FirestoreTransaction: @unchecked Sendable {
    nonisolated(unsafe) private let wrapped: any FirestoreTransactionProtocol
    private let referenceProvider: any FirestoreReferenceProvider
    let writeTracker = FirestoreWriteTracker()

    init<Transport: ClientTransport>(
        wrapping transaction: Transaction<Transport>,
        firestore: Firestore<Transport>
    ) {
        self.wrapped = transaction
        self.referenceProvider = firestore
    }

    init(
        wrapping protocol: any FirestoreTransactionProtocol,
        referenceProvider: any FirestoreReferenceProvider
    ) {
        self.wrapped = `protocol`
        self.referenceProvider = referenceProvider
    }

    // MARK: Reference Forming

    func collection(_ collectionID: String) -> CollectionReference {
        referenceProvider.collection(collectionID)
    }

    func document(_ documentID: String) -> DocumentReference {
        referenceProvider.document(documentID)
    }

    func collectionGroup(_ groupID: String) -> CollectionGroup {
        referenceProvider.collectionGroup(groupID)
    }

    // MARK: Aggregation Reads

    /// Counts every document in `collection` (unfiltered).
    ///
    /// This is ALWAYS a non-transactional read, even when the wrapper wraps a
    /// live transaction: aggregations don't carry the transaction id here.
    func count(_ collection: CollectionReference) async throws -> Int {
        try await referenceProvider.count(collection)
    }

    // MARK: Transactional Reads

    func get(documentReference: DocumentReference) async throws -> DocumentSnapshot {
        try await wrapped.get(documentReference: documentReference)
    }

    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot {
        try await wrapped.get(query: query)
    }

    // MARK: Transactional Writes

    func create(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        try await wrapped.create(documentReference: documentReference, data: data)
    }

    func set(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        try await wrapped.set(documentReference: documentReference, data: data)
    }

    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) async throws {
        writeTracker.recordWrite()
        try await wrapped.set(documentReference: documentReference, data: data, merge: merge)
    }

    func update(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        try await wrapped.update(documentReference: documentReference, data: data)
    }

    func delete(documentReference: DocumentReference) async throws {
        writeTracker.recordWrite()
        try await wrapped.delete(documentReference: documentReference)
    }
}

extension FirestoreTransaction {
    /// Never-existing document used to give a write-less transaction one harmless write.
    static let noopCommitDocumentPath = "_noop_commit/empty"
}

// MARK: - Non-Transactional (Direct) Access

/// Implements `FirestoreTransactionProtocol` by delegating directly to
/// `Firestore<Transport>` without an active transaction.
///
/// Both reads and writes hit Firestore immediately (no transaction ID).
private final class DirectFirestoreAccess<Transport: ClientTransport>: FirestoreTransactionProtocol {

    private let firestore: Firestore<Transport>

    init(firestore: Firestore<Transport>) {
        self.firestore = firestore
    }

    func get(documentReference: DocumentReference) async throws -> DocumentSnapshot {
        try await documentReference.getDocument(firestore: firestore)
    }

    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot {
        try await query.getDocuments(firestore: firestore)
    }

    func create(documentReference: DocumentReference, data: [String: Any]) async throws {
        try await documentReference.setData(data, firestore: firestore)
    }

    func set(documentReference: DocumentReference, data: [String: Any]) async throws {
        try await documentReference.setData(data, firestore: firestore)
    }

    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) async throws {
        try await documentReference.setData(data, merge: merge, firestore: firestore)
    }

    func update(documentReference: DocumentReference, data: [String: Any]) async throws {
        try await documentReference.updateData(data, firestore: firestore)
    }

    func delete(documentReference: DocumentReference) async throws {
        try await documentReference.delete(firestore: firestore)
    }
}

extension FirestoreTransaction {

    /// Creates a `FirestoreTransaction` that performs direct (non-transactional)
    /// Firestore reads. Suitable for query handlers and services that operate
    /// outside the UnitOfWork / transaction boundary.
    static func direct<Transport: ClientTransport>(
        firestore: Firestore<Transport>
    ) -> FirestoreTransaction {
        FirestoreTransaction(
            wrapping: DirectFirestoreAccess(firestore: firestore),
            referenceProvider: firestore
        )
    }
}

// MARK: - Codable Convenience

extension FirestoreTransaction {

    // MARK: Decodable Reads

    func getDocument<T: Decodable>(
        _ type: T.Type,
        documentReference: DocumentReference
    ) async throws -> T? {
        let snapshot = try await get(documentReference: documentReference)
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return try FirestoreDecoder().decode(type, from: data, in: documentReference)
    }

    func getDocuments<T: Decodable>(
        _ type: T.Type,
        query: FirestoreAPI.Query
    ) async throws -> [T] {
        let snapshot = try await get(query: query)
        return try snapshot.documents.compactMap { doc in
            guard let data = doc.data() else { return nil }
            return try FirestoreDecoder().decode(type, from: data, in: doc.documentReference)
        }
    }

    func getDocuments<T: Decodable>(
        _ type: T.Type,
        collection: CollectionReference
    ) async throws -> [T] {
        // CollectionReference.toQuery() is internal to FirestoreAPI,
        // so we use the underlying get(query:) via an empty-predicate query
        // constructed through a public API.
        try await getDocuments(type, query: collection.and([]))
    }

    // MARK: Encodable Writes

    func create<T: Encodable>(documentReference: DocumentReference, from data: T) async throws {
        let documentData = try FirestoreEncoder().encode(data)
        try await create(documentReference: documentReference, data: documentData)
    }

    func set<T: Encodable>(documentReference: DocumentReference, from data: T) async throws {
        let documentData = try FirestoreEncoder().encode(data)
        try await set(documentReference: documentReference, data: documentData)
    }

    func set<T: Encodable>(documentReference: DocumentReference, from data: T, merge: Bool) async throws {
        let documentData = try FirestoreEncoder().encode(data)
        try await set(documentReference: documentReference, data: documentData, merge: merge)
    }

    func update<T: Encodable>(documentReference: DocumentReference, from data: T) async throws {
        let documentData = try FirestoreEncoder().encode(data)
        try await update(documentReference: documentReference, data: documentData)
    }
}

// MARK: - Firestore Extension

extension Firestore {

    func runInTransaction<T>(
        _ transactionFunction: @escaping (FirestoreTransaction) async throws -> T,
        options: TransactionOptions = TransactionOptions()
    ) async throws -> T {
        let result: T? = try await runInTransaction(transactionFunction, options: options)
        guard let result else {
            throw FirestoreError.transactionReturnedNil
        }
        return result
    }

    func runInTransaction<T>(
        _ transactionFunction: @escaping (FirestoreTransaction) async throws -> T,
        options: TransactionOptions = TransactionOptions()
    ) async throws -> T? {
        try await self.runTransaction({ transaction in
            let wrapper = FirestoreTransaction(wrapping: transaction, firestore: self)
            let result = try await transactionFunction(wrapper)
            // A write-less body (inbox duplicate, idempotent replay, "not found"
            // early return) would make the pinned runner's commit() throw
            // `commitFailed` against the emulator and retry 5x. Buffer one no-op
            // delete of a document that never exists so the commit carries a
            // write and answers with a commitTime. Deleting a missing document
            // changes nothing and fires no triggers.
            if wrapper.writeTracker.writeCount == 0 {
                transaction.delete(documentReference: self.document(FirestoreTransaction.noopCommitDocumentPath))
            }
            return result
        }, options: options)!
    }

}
