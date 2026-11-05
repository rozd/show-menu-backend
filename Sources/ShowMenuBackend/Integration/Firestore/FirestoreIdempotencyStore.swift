import Foundation
import FirestoreAPI
import GRPCCore
import Logging

// MARK: - Persisted model

/// Firestore representation of an ``IdempotencyRecord``.
///
/// The document id *is* the scoped, hashed record id (`@DocumentID`, never a
/// field). The response body is stored base64-encoded as a string for encoder
/// portability. `expiresAt` is a real `Timestamp` so a Firestore **TTL policy**
/// on this field can reclaim expired records out of band.
struct IdempotencyRecordModel: Codable, Sendable {

    @DocumentID
    var id: String

    let fingerprint: String
    let status: String
    let responseStatus: Int?
    /// Base64 of the captured response body.
    let responseBody: String?
    let createdAt: Timestamp
    let expiresAt: Timestamp
}

// MARK: - Store

/// Firestore-backed ``IdempotencyStore`` that enlists in an active
/// `FirestoreTransaction` — the *same* transaction the command's writes use, so
/// the de-duplication record and the work commit (or roll back) atomically.
///
/// The in-flight guard for the new-key race is a transactional `create` with the
/// `exists == false` precondition (the `FirebaseAPI` client sets it on `create`);
/// concurrent writers that lose the precondition at commit are retried by the
/// transaction runner and, on retry, observe the now-committed record and replay.
///
/// Retention: `complete` stamps `expiresAt = now + ttl`; a probe past that
/// instant treats the slot as empty (and overwrites it), independent of the
/// out-of-band Firestore TTL policy that physically deletes expired documents.
struct FirestoreIdempotencyStore: IdempotencyStore {

    static let defaultCollection = "idempotency_keys"

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

    func reserve(
        id: String,
        fingerprint: RequestFingerprint
    ) async throws -> IdempotencyReservation {
        let docRef = transaction.collection(collectionPath).document(id)
        logger.debug("Idempotency reserve", metadata: [
            "collection": .string(collectionPath), "id": .string(id)
        ])

        // Probe phase: only Firestore/gRPC errors are caught here.
        // Domain errors (e.g. IdempotencyError.corruptRecord) must propagate
        // unchanged, so storedResponse(from:) is called outside this block.
        let existing: IdempotencyRecordModel?
        do {
            existing = try await transaction.getDocument(
                IdempotencyRecordModel.self, documentReference: docRef
            )
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Idempotency reserve failed", metadata: [
                "collection": .string(collectionPath), "id": .string(id),
                "mappedError": .string(String(describing: mapped))
            ])
            throw mapped
        }

        guard let existing else {
            // Empty slot — proceed and `create` (uniqueness precondition).
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: false))
        }

        // Expired record occupies the slot → treat as empty, but overwrite.
        // Both sides compare at whole-second resolution: `Timestamp(_:)` stores
        // `nanos: 0`, and the live clock is truncated here too — so a slot can read
        // as expired up to ~1s early. Negligible at the 24h default TTL; the `now`
        // seam keeps the boundary testable if TTL is ever shortened to seconds.
        if existing.expiresAt.seconds <= Int64(now().timeIntervalSince1970) {
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: true))
        }

        // Same key, different body → client misuse.
        guard existing.fingerprint == fingerprint.value else {
            return .mismatch
        }

        switch IdempotencyStatus(rawValue: existing.status) {
        case .completed:
            // storedResponse(from:) may throw IdempotencyError.corruptRecord —
            // let that propagate directly (not through the gRPC-mapping catch above).
            return .replay(try storedResponse(from: existing))
        case .inProgress, .none:
            return .inProgress
        }
    }

    // MARK: Write phase

    func complete(
        ticket: IdempotencyTicket,
        response: StoredResponse
    ) async throws {
        let instant = now()
        let model = IdempotencyRecordModel(
            id: ticket.id,
            fingerprint: ticket.fingerprint.value,
            status: IdempotencyStatus.completed.rawValue,
            responseStatus: response.status,
            responseBody: response.body.base64EncodedString(),
            createdAt: Timestamp(instant),
            expiresAt: Timestamp(instant.addingTimeInterval(ttl))
        )
        let docRef = transaction.collection(collectionPath).document(ticket.id)
        logger.debug("Idempotency complete", metadata: [
            "collection": .string(collectionPath), "id": .string(ticket.id),
            "overwriteExpired": .stringConvertible(ticket.overwriteExpired)
        ])
        do {
            if ticket.overwriteExpired {
                // Expired slot: plain `set` (no `exists` precondition) is safe under
                // serializable transactions. `reserve` already read this document with
                // the transaction id, so it is in the read-set: if a concurrent writer
                // commits first, this commit aborts (gRPC `.aborted`) and the runner
                // retries — and the retry's `reserve` sees the fresh record and replays.
                try await transaction.set(documentReference: docRef, from: model)
            } else {
                // Empty slot: transactional create — `exists == false` is the
                // in-flight uniqueness guard, enforced atomically at commit.
                try await transaction.create(documentReference: docRef, from: model)
            }
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Idempotency complete failed", metadata: [
                "collection": .string(collectionPath), "id": .string(ticket.id),
                "mappedError": .string(String(describing: mapped))
            ])
            throw mapped
        }
    }

    // MARK: Mapping

    private func storedResponse(from model: IdempotencyRecordModel) throws -> StoredResponse {
        let body: Data
        if let encoded = model.responseBody {
            guard let decoded = Data(base64Encoded: encoded) else {
                // Body was persisted but is not valid base64 — a corrupt record,
                // not a client fault; surface it instead of replaying empty Data
                // that would later fail JSON decoding as an opaque 500.
                throw IdempotencyError.corruptRecord(id: model.id)
            }
            body = decoded
        } else {
            // A `completed` record always has a body — `complete` encodes and stores
            // one as its final write. A nil here is therefore corrupt state (a
            // hand-edited document or a pre-schema record), equally broken as invalid
            // base64. Surface it as corruptRecord rather than substituting empty Data
            // that would later fail JSON decoding as an opaque 500.
            throw IdempotencyError.corruptRecord(id: model.id)
        }
        return StoredResponse(status: model.responseStatus ?? 200, body: body)
    }
}
