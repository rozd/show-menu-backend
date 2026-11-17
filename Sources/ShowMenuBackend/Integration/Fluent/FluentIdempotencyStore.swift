//
//  FluentIdempotencyStore.swift
//  ShowMenuBackend
//
//  Fluent binding of the inbound-command de-duplication store.
//

import Foundation
import Logging
import Fluent

// MARK: - Record

/// Stored representation of an ``IdempotencyRecord``.
///
/// The record id *is* the primary key (scoped and hashed by
/// ``IdempotencyScope/recordId(key:commandType:principalId:)``), never a field —
/// which is what makes the uniqueness constraint the in-flight guard. The response
/// body is `bytea` (no base64 detour: a relational column stores bytes natively),
/// and `expires_at` is a real timestamp so a TTL sweep can reclaim expired rows out
/// of band.
final class IdempotencyKeyRecord: Model, @unchecked Sendable {

    static let schema = "idempotency_keys"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "fingerprint")
    var fingerprint: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "response_status")
    var responseStatus: Int?

    @OptionalField(key: "response_body")
    var responseBody: Data?

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(
        id: String,
        fingerprint: String,
        status: IdempotencyStatus,
        response: StoredResponse?,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.status = status.rawValue
        self.responseStatus = response?.status
        self.responseBody = response?.body
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Store

/// Fluent ``IdempotencyStore``, enlisting in the command's own transaction — so the
/// de-duplication record and the work commit (or roll back) atomically.
///
/// The in-flight guard for the new-key race is the table's **primary key**: two
/// concurrent first-time requests with the same key cannot both `INSERT`; the
/// loser's statement violates the constraint, which aborts its whole transaction,
/// and its retry observes the committed record and replays.
///
/// The read-before-write ordering the ``IdempotencyStore`` contract mandates is
/// trivially satisfiable here — Postgres has no problem reading after a write — but
/// it is kept anyway: the contract exists so the *strictest* store can bind it, and
/// diverging would make this adapter a poor reference for the next one.
///
/// Retention: `complete` stamps `expiresAt = now + ttl`; a probe past that instant
/// treats the slot as empty (and overwrites it).
struct FluentIdempotencyStore: IdempotencyStore {

    let transaction: FluentTransaction
    let ttl: TimeInterval
    /// Clock seam — injected so tests can drive expiry deterministically.
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        transaction: FluentTransaction,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.transaction = transaction
        self.ttl = ttl
        self.now = now
        self.logger = logger
    }

    private var database: any Database { transaction.database }

    // MARK: Read phase

    func reserve(
        id: String,
        fingerprint: RequestFingerprint
    ) async throws -> IdempotencyReservation {
        logger.debug("Idempotency reserve", metadata: [
            "table": .string(IdempotencyKeyRecord.schema), "id": .string(id)
        ])

        guard let existing = try await IdempotencyKeyRecord.find(id, on: database) else {
            // Empty slot — proceed and INSERT (the primary key is the guard).
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: false))
        }

        // Expired record occupies the slot → treat as empty, but overwrite.
        if existing.expiresAt <= now() {
            return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: true))
        }

        // Same key, different body → client misuse.
        guard existing.fingerprint == fingerprint.value else {
            return .mismatch
        }

        switch IdempotencyStatus(rawValue: existing.status) {
        case .completed:
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
        logger.debug("Idempotency complete", metadata: [
            "table": .string(IdempotencyKeyRecord.schema), "id": .string(ticket.id),
            "overwriteExpired": .stringConvertible(ticket.overwriteExpired)
        ])

        if ticket.overwriteExpired, let existing = try await IdempotencyKeyRecord.find(ticket.id, on: database) {
            existing.fingerprint = ticket.fingerprint.value
            existing.status = IdempotencyStatus.completed.rawValue
            existing.responseStatus = response.status
            existing.responseBody = response.body
            existing.createdAt = instant
            existing.expiresAt = instant.addingTimeInterval(ttl)
            try await existing.update(on: database)
            return
        }

        let record = IdempotencyKeyRecord(
            id: ticket.id,
            fingerprint: ticket.fingerprint.value,
            status: .completed,
            response: response,
            createdAt: instant,
            expiresAt: instant.addingTimeInterval(ttl)
        )
        do {
            try await record.create(on: database)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // A concurrent duplicate committed first. Its response is now the
            // canonical one; this transaction is already doomed (Postgres aborts it
            // on the violation), so report the race rather than a store failure —
            // the client retries and replays.
            logger.info("Idempotency slot lost the insert race", metadata: [
                "table": .string(IdempotencyKeyRecord.schema), "id": .string(ticket.id)
            ])
            throw IdempotencyError.requestInProgress(key: ticket.id)
        }
    }

    // MARK: Mapping

    private func storedResponse(from record: IdempotencyKeyRecord) throws -> StoredResponse {
        // A `completed` record always has a body — `complete` stores one as its
        // final write. A missing body is therefore corrupt state (hand-edited, or a
        // pre-schema row); surface it rather than replaying empty `Data` that would
        // later fail JSON decoding as an opaque 500 with no explanation.
        guard let body = record.responseBody else {
            throw IdempotencyError.corruptRecord(id: record.id ?? "<unknown>")
        }
        return StoredResponse(status: record.responseStatus ?? 200, body: body)
    }
}
