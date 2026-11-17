//
//  FluentInboxStore.swift
//  ShowMenuBackend
//
//  Fluent binding of the consumer-side event de-duplication store.
//

import Foundation
import Logging
import Fluent

// MARK: - Record

/// Stored representation of an ``InboxRecord``.
///
/// The record id *is* the primary key (consumer + event id, hashed by
/// ``InboxRecordId/derive(consumer:eventId:)``), never a field — which is what
/// makes the uniqueness constraint the in-flight guard. `processed_at` and
/// `expires_at` are real timestamps so a TTL sweep can reclaim expired rows out
/// of band.
final class InboxMessageRecord: Model, @unchecked Sendable {

    static let schema = "inbox"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "processed_at")
    var processedAt: Date

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(
        id: String,
        processedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.processedAt = processedAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Store

/// Fluent ``InboxStore``, enlisting in the handler's own transaction — so the
/// processed-event marker and the work commit (or roll back) atomically.
///
/// The in-flight guard for the new-event race is the table's **primary key**:
/// two concurrent first-time handlers for the same event cannot both `INSERT`;
/// the loser's statement violates the constraint, which aborts its whole
/// transaction, and its retry observes the committed record and skips the work.
///
/// The read-before-write ordering the ``InboxStore`` contract mandates is
/// trivially satisfiable here — Postgres has no problem reading after a write —
/// but it is kept anyway: the contract exists so the *strictest* store can bind
/// it, and diverging would make this adapter a poor reference for the next one.
///
/// Retention: `complete` stamps `expiresAt = now + ttl`; a probe past that
/// instant treats the slot as empty (and overwrites it).
struct FluentInboxStore: InboxStore {

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

    func reserve(id: String) async throws -> InboxReservation {
        logger.debug("Inbox reserve", metadata: [
            "table": .string(InboxMessageRecord.schema), "id": .string(id)
        ])

        guard let existing = try await InboxMessageRecord.find(id, on: database) else {
            // Empty slot — proceed and INSERT (the primary key is the guard).
            return .proceed(InboxTicket(id: id, overwriteExpired: false))
        }

        // Expired record occupies the slot → treat as empty, but overwrite.
        if existing.expiresAt <= now() {
            return .proceed(InboxTicket(id: id, overwriteExpired: true))
        }

        // Record exists and is not expired — event already processed.
        logger.debug("Inbox duplicate skipped", metadata: [
            "table": .string(InboxMessageRecord.schema), "id": .string(id)
        ])
        return .alreadyProcessed
    }

    // MARK: Write phase

    func complete(ticket: InboxTicket) async throws {
        let instant = now()
        logger.debug("Inbox complete", metadata: [
            "table": .string(InboxMessageRecord.schema), "id": .string(ticket.id),
            "overwriteExpired": .stringConvertible(ticket.overwriteExpired)
        ])

        if ticket.overwriteExpired, let existing = try await InboxMessageRecord.find(ticket.id, on: database) {
            existing.processedAt = instant
            existing.expiresAt = instant.addingTimeInterval(ttl)
            try await existing.update(on: database)
            return
        }

        let record = InboxMessageRecord(
            id: ticket.id,
            processedAt: instant,
            expiresAt: instant.addingTimeInterval(ttl)
        )
        do {
            try await record.create(on: database)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // A concurrent duplicate committed first. This transaction is already
            // doomed (Postgres aborts it on the violation), so report the race
            // rather than a store failure — the dispatcher catches and logs it.
            logger.info("Inbox slot lost the insert race", metadata: [
                "table": .string(InboxMessageRecord.schema), "id": .string(ticket.id)
            ])
            throw InboxError.duplicateEvent(id: ticket.id)
        }
    }
}
