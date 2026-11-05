import Foundation
import FirestoreAPI
import GRPCCore
import Logging

// MARK: - Persisted model

/// Firestore representation of an ``InboxRecord``.
///
/// The document id *is* the per-consumer, per-event hashed record id
/// (`@DocumentID`, never a field). `expiresAt` is a real `Timestamp` so a
/// Firestore **TTL policy** on this field can reclaim expired markers out of band.
struct InboxRecordModel: Codable, Sendable {

    @DocumentID
    var id: String

    let processedAt: Timestamp
    let expiresAt: Timestamp
}

// MARK: - Store

/// Firestore-backed ``InboxStore`` that enlists in an active
/// `FirestoreTransaction` — the *same* transaction the command's writes use, so
/// the processed-event marker and the work commit (or roll back) atomically.
///
/// The in-flight guard for the concurrent-duplicate race is a transactional
/// `create` with the `exists == false` precondition (the `FirebaseAPI` client
/// sets it on `create`). The write is only *buffered* in `complete`; the
/// precondition is enforced at commit. A loser's commit therefore fails there,
/// and `runTransaction` retries the whole closure (it retries every error, not
/// just `ABORTED`, up to its attempt limit): on the retry `reserve` observes the
/// committed marker and skips silently. If the conflict outlasts every attempt it
/// escapes `FirestoreTransactionUnitOfWork` as a mapped `FirestoreError`.
///
/// Retention: `complete` stamps `expiresAt = now + ttl`; a probe past that
/// instant treats the slot as empty (and overwrites it), independent of the
/// out-of-band Firestore TTL policy that physically deletes expired documents.
struct FirestoreInboxStore: InboxStore {

    static let defaultCollection = "inbox_records"

    let transaction: FirestoreTransaction
    let collectionPath: String
    let ttl: TimeInterval
    /// Clock seam — injected so tests can drive expiry deterministically.
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        transaction: FirestoreTransaction,
        collectionPath: String,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.transaction = transaction
        self.collectionPath = collectionPath
        self.ttl = ttl
        self.now = now
        self.logger = logger
    }

    // MARK: Read phase

    func reserve(id: String) async throws -> InboxReservation {
        let docRef = transaction.collection(collectionPath).document(id)
        logger.debug("Inbox reserve", metadata: [
            "collection": .string(collectionPath), "id": .string(id)
        ])

        let existing: InboxRecordModel?
        do {
            existing = try await transaction.getDocument(
                InboxRecordModel.self, documentReference: docRef
            )
        } catch let decoding as DecodingError {
            logger.error("Inbox record is corrupt", metadata: [
                "collection": .string(collectionPath), "id": .string(id),
                "error": .string(String(describing: decoding))
            ])
            throw InboxError.corruptRecord(id: id)
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Inbox reserve failed", metadata: [
                "collection": .string(collectionPath), "id": .string(id),
                "mappedError": .string(String(describing: mapped))
            ])
            throw mapped
        }

        guard let existing else {
            // Empty slot — proceed and `create` (uniqueness precondition).
            return .proceed(InboxTicket(id: id, overwriteExpired: false))
        }

        // Expired marker occupies the slot → treat as empty, but overwrite.
        // Whole-second comparison, as in `FirestoreIdempotencyStore`.
        if existing.expiresAt.seconds <= Int64(now().timeIntervalSince1970) {
            return .proceed(InboxTicket(id: id, overwriteExpired: true))
        }

        return .alreadyProcessed
    }

    // MARK: Write phase

    func complete(ticket: InboxTicket) async throws {
        let instant = now()
        let model = InboxRecordModel(
            id: ticket.id,
            processedAt: Timestamp(instant),
            expiresAt: Timestamp(instant.addingTimeInterval(ttl))
        )
        let docRef = transaction.collection(collectionPath).document(ticket.id)
        logger.debug("Inbox complete", metadata: [
            "collection": .string(collectionPath), "id": .string(ticket.id),
            "overwriteExpired": .stringConvertible(ticket.overwriteExpired)
        ])
        do {
            if ticket.overwriteExpired {
                // Expired slot: plain `set`. `reserve` read this document in the
                // same transaction, so a concurrent writer committing first aborts
                // this commit and the runner retries; the retry's `reserve` skips.
                try await transaction.set(documentReference: docRef, from: model)
            } else {
                // Empty slot: transactional create — `exists == false` is the
                // uniqueness guard, enforced atomically at commit.
                try await transaction.create(documentReference: docRef, from: model)
            }
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Inbox complete failed", metadata: [
                "collection": .string(collectionPath), "id": .string(ticket.id),
                "mappedError": .string(String(describing: mapped))
            ])
            if case .documentAlreadyExists = mapped {
                throw InboxError.duplicateEvent(id: ticket.id)
            }
            throw mapped
        }
    }
}
