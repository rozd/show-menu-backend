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

    // MARK: Read cache

    /// Document snapshots already read through this (live) transaction, by document path.
    /// A transaction reads one consistent snapshot, so a repeated read of the same document
    /// is answered locally. This is what lets several versioned aggregates be updated in one
    /// unit of work: each check-and-set write re-reads its document (see
    /// `FirestoreDataSource.update(model:ifMatching:)`), and the pinned client forbids reads
    /// after the first write; the re-read hits the snapshot the repository's `fetch` took.
    private var snapshots: [String: DocumentSnapshot] = [:]

    func cachedSnapshot(for path: String) -> DocumentSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[path]
    }

    func cache(_ snapshot: DocumentSnapshot, for path: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots[path] = snapshot
    }

    /// A write makes the cached snapshot stale; drop it (a later read then goes to the
    /// server, as before).
    func invalidate(path: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots[path] = nil
    }
}

struct FirestoreTransaction: @unchecked Sendable {
    nonisolated(unsafe) private let wrapped: any FirestoreTransactionProtocol
    private let referenceProvider: any FirestoreReferenceProvider
    let writeTracker = FirestoreWriteTracker()
    /// Only a live transaction has a consistent snapshot to cache; direct reads never cache.
    private let cachesReads: Bool

    init<Transport: ClientTransport>(
        wrapping transaction: Transaction<Transport>,
        firestore: Firestore<Transport>
    ) {
        self.wrapped = transaction
        self.referenceProvider = firestore
        self.cachesReads = true
    }

    init(
        wrapping protocol: any FirestoreTransactionProtocol,
        referenceProvider: any FirestoreReferenceProvider,
        cachesReads: Bool = false
    ) {
        self.wrapped = `protocol`
        self.referenceProvider = referenceProvider
        self.cachesReads = cachesReads
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
        guard cachesReads else { return try await wrapped.get(documentReference: documentReference) }
        if let cached = writeTracker.cachedSnapshot(for: documentReference.path) { return cached }
        let snapshot = try await wrapped.get(documentReference: documentReference)
        writeTracker.cache(snapshot, for: documentReference.path)
        return snapshot
    }

    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot {
        try await wrapped.get(query: query)
    }

    // MARK: Transactional Writes

    func create(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        writeTracker.invalidate(path: documentReference.path)
        try await wrapped.create(documentReference: documentReference, data: data)
    }

    func set(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        writeTracker.invalidate(path: documentReference.path)
        try await wrapped.set(documentReference: documentReference, data: data)
    }

    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) async throws {
        writeTracker.recordWrite()
        writeTracker.invalidate(path: documentReference.path)
        try await wrapped.set(documentReference: documentReference, data: data, merge: merge)
    }

    func update(documentReference: DocumentReference, data: [String: Any]) async throws {
        writeTracker.recordWrite()
        writeTracker.invalidate(path: documentReference.path)
        try await wrapped.update(documentReference: documentReference, data: data)
    }

    func delete(documentReference: DocumentReference) async throws {
        writeTracker.recordWrite()
        writeTracker.invalidate(path: documentReference.path)
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
        readOnly: Bool = false,
        readTime: Timestamp? = nil,
        maxAttempts: Int = 5
    ) async throws -> T {
        let result: T? = try await runInTransaction(
            transactionFunction, readOnly: readOnly, readTime: readTime, maxAttempts: maxAttempts
        )
        guard let result else {
            throw FirestoreError.transactionReturnedNil
        }
        return result
    }

    /// Runs `transactionFunction` in a Firestore transaction, retrying ONLY
    /// transient Firestore failures (see `TransactionRetryClassifier`).
    ///
    /// The pinned `Firestore.runTransaction` retries the closure on *any*
    /// thrown error (5 attempts, ~3.5 s), so a domain/application error
    /// (403/404/409/422, `ConcurrencyError`, idempotency rejections) would be
    /// re-run five times before surfacing. We call it with `maxAttempts: 1`
    /// (exactly one attempt — it still sleeps one ~0.25 s backoff before
    /// giving up, which is the floor for a failing request) and run our own
    /// attempt loop: a transient failure is retried, anything else is rethrown
    /// immediately and unwrapped (the library has already rolled back). An
    /// exhausted transient failure is thrown as
    /// `FirestoreAPI.FirestoreError.transactionFailed`, as before.
    func runInTransaction<T>(
        _ transactionFunction: @escaping (FirestoreTransaction) async throws -> T,
        readOnly: Bool = false,
        readTime: Timestamp? = nil,
        maxAttempts: Int = 5
    ) async throws -> T? {
        var attempt = 1
        while true {
            do {
                return try await self.runTransaction({ transaction in
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
                }, options: TransactionOptions(maxAttempts: 1, readOnly: readOnly, readTime: readTime))
            } catch {
                let underlying = TransactionRetryClassifier.unwrap(error)
                guard TransactionRetryClassifier.isTransient(underlying) else {
                    throw underlying
                }
                guard attempt < maxAttempts else {
                    throw FirestoreAPI.FirestoreError.transactionFailed(error: underlying)
                }
                // The library already slept ~0.25 s after the failed attempt;
                // top up to the legacy 0.25 s x 1.5^n schedule.
                let extra = TransactionRetryClassifier.extraDelay(forAttempt: attempt)
                if extra > 0 {
                    try await Task.sleep(for: .seconds(extra))
                }
                attempt += 1
            }
        }
    }

}

/// Pure classification of what a failed transaction attempt means.
enum TransactionRetryClassifier {

    /// The legacy library schedule (0.25 s x 1.5^n); its own one-attempt run
    /// already waits `libraryDelay` after each failure.
    static let backoff = RetryPolicy.Backoff.exponential(initial: 0.25, multiplier: 1.5, cap: 60)
    static let libraryDelay: TimeInterval = 0.25

    static func extraDelay(forAttempt attempt: Int) -> TimeInterval {
        max(0, backoff.delay(forAttempt: attempt) - libraryDelay)
    }

    /// Strips the runner's `transactionFailed` wrapper(s).
    static func unwrap(_ error: any Error) -> any Error {
        var current = error
        while let api = current as? FirestoreAPI.FirestoreError, case .transactionFailed(let inner) = api {
            current = inner
        }
        return current
    }

    /// Whether `error` (already unwrapped) is a transient Firestore failure
    /// worth re-running the whole closure for. Everything not originating in
    /// the Firestore/gRPC transport (domain, application, `ConcurrencyError`,
    /// idempotency, cancellation) is NOT transient.
    ///
    /// `alreadyExists` / `failedPrecondition` DO retry: a marker-doc `create`
    /// (plan_skus, inbox, idempotency, checkout_locks) that loses a race fails
    /// at commit, and the retry's re-read sees the winner.
    static func isTransient(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let rpc = error as? RPCError { return isTransient(code: rpc.code) }
        if let api = error as? FirestoreAPI.FirestoreError {
            switch api {
            case .rpcError(let rpc): return isTransient(code: rpc.code)
            case .timeout, .maxAttemptsReached: return true
            default: return false
            }
        }
        if let ours = error as? FirestoreError { return ours.isRetryable }
        // `TransactionError` is internal to FirebaseAPI, so match by name.
        // `commitFailed` = the commit returned no commit time / aborted.
        if "\(type(of: error))" == "TransactionError", "\(error)" == "commitFailed" { return true }
        return false
    }

    static func isTransient(code: RPCError.Code) -> Bool {
        switch code {
        case .aborted, .alreadyExists, .failedPrecondition,
             .unavailable, .deadlineExceeded, .resourceExhausted:
            return true
        default:
            return false
        }
    }
}
