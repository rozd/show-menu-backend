//
//  FluentOutboxStore.swift
//  ShowMenuBackend
//
//  Fluent binding of the transactional outbox.
//

import Foundation
import Logging
import Fluent

// MARK: - Record

/// Stored representation of an ``OutboxMessage`` — a real table with real columns.
///
/// This one *is* modelled with Fluent's ORM, unlike the module data sources: the
/// outbox schema is fixed and known here, so there is no genericity to fight, and
/// the typed query builder reads better than hand-written SQL for the relay's
/// filter/sort/limit. The payload is `bytea` (the envelope's JSON bytes) and the
/// status, timestamps and `available_at` are indexable columns, which is what lets
/// the relay's drain query be a cheap index scan rather than a full read.
///
/// > Note: a Fluent model's table name is **static**. `Outbox.collection` is
/// > therefore not free to differ from ``schema`` under this adapter; `configure`
/// > checks that at startup and refuses to boot on a mismatch rather than reading
/// > and writing different tables.
final class OutboxMessageRecord: Model, @unchecked Sendable {

    static let schema = "outbox"

    @ID(custom: .id, generatedBy: .user)
    var id: UUID?

    @Field(key: "kind")
    var kind: String

    @Field(key: "payload")
    var payload: Data

    @Field(key: "origin")
    var origin: String

    @OptionalField(key: "correlation_id")
    var correlationId: String?

    @OptionalField(key: "occurred_at")
    var occurredAt: Date?

    @Field(key: "sequence")
    var sequence: Int

    @Field(key: "status")
    var status: String

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "published_at")
    var publishedAt: Date?

    @Field(key: "attempts")
    var attempts: Int

    @Field(key: "available_at")
    var availableAt: Date

    @OptionalField(key: "last_error")
    var lastError: String?

    init() {}

    init(_ message: OutboxMessage) {
        self.id = message.id
        self.kind = message.kind
        self.payload = message.payload
        self.origin = message.metadata.origin
        self.correlationId = message.metadata.correlationId?.rawValue
        self.occurredAt = message.metadata.occurredAt
        self.sequence = message.sequence
        self.status = message.status.rawValue
        self.createdAt = message.createdAt
        self.publishedAt = message.publishedAt
        self.attempts = message.attempts
        self.availableAt = message.availableAt
        self.lastError = message.lastError
    }

    func toMessage() throws -> OutboxMessage {
        OutboxMessage(
            id: try requireID(),
            kind: kind,
            payload: payload,
            metadata: IntegrationEventMetadata(
                origin: origin,
                correlationId: correlationId.map { TraceID(stringLiteral: $0) },
                occurredAt: occurredAt ?? createdAt
            ),
            sequence: sequence,
            status: OutboxMessage.Status(rawValue: status) ?? .pending,
            createdAt: createdAt,
            publishedAt: publishedAt,
            attempts: attempts,
            availableAt: availableAt,
            lastError: lastError
        )
    }
}

// MARK: - Store

/// Fluent ``OutboxStore``.
///
/// The **write side** (`append`) runs on the transaction's connection — the same
/// one the ``Repository`` uses for the command's state change — so the row is part
/// of that transaction and commits atomically with it (or rolls back). This is how
/// the outbox enlists in the Unit of Work: it never opens its own connection.
///
/// The **relay side** is constructed with `.direct(database:)` to read, mark and
/// prune rows outside any command transaction.
struct FluentOutboxStore: OutboxStore {

    let transaction: FluentTransaction
    /// Retained for diagnostics; the table itself is fixed by
    /// ``OutboxMessageRecord/schema`` (see the note there).
    let table: String
    let logger: Logger

    init(transaction: FluentTransaction, table: String = OutboxMessageRecord.schema, logger: Logger) {
        self.transaction = transaction
        self.table = table
        self.logger = logger
    }

    private var database: any Database { transaction.database }

    // MARK: Write side

    func append(_ message: OutboxMessage) async throws {
        logger.debug("Appending outbox message", metadata: [
            "table": .string(OutboxMessageRecord.schema),
            "messageId": .string(message.id.uuidString),
            "kind": .string(message.kind)
        ])

        if !transaction.isTransactional {
            // The row would still be written, but on its own connection — the
            // atomicity the outbox exists for would be gone, quietly.
            logger.warning("Outbox append outside a transaction; the message is not atomic with the state change", metadata: [
                "messageId": .string(message.id.uuidString)
            ])
        }

        do {
            // A plain INSERT (not an upsert): the row id is the event id, so
            // re-recording the same event must collide, not duplicate.
            try await OutboxMessageRecord(message).create(on: database)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw FluentStoreError.alreadyExists(
                table: OutboxMessageRecord.schema, id: message.id.uuidString
            )
        }
    }

    // MARK: Relay side

    func pending(limit: Int, now: Date) async throws -> [OutboxMessage] {
        // Pushed down to the database rather than filtered in-process:
        // scan. The ordering contract is what matters and is preserved:
        // `createdAt`, then `sequence`.
        let records = try await OutboxMessageRecord.query(on: database)
            .filter(\.$status == OutboxMessage.Status.pending.rawValue)
            .filter(\.$availableAt <= now)
            .sort(\.$createdAt, .ascending)
            .sort(\.$sequence, .ascending)
            .limit(limit)
            .all()

        // One poisoned row must not stall the whole relay.
        return records.compactMap { record in
            do {
                return try record.toMessage()
            } catch {
                logger.warning("Outbox message decode failed; skipping", metadata: [
                    "table": .string(OutboxMessageRecord.schema),
                    "error": .string(String(describing: error))
                ])
                return nil
            }
        }
    }

    func markPublished(id: UUID, at: Date) async throws {
        guard let record = try await OutboxMessageRecord.find(id, on: database) else {
            return // already gone — idempotent
        }
        record.status = OutboxMessage.Status.published.rawValue
        record.publishedAt = at
        record.lastError = nil
        try await record.update(on: database)
    }

    func recordFailure(id: UUID, attempts: Int, availableAt: Date, error: String) async throws {
        guard let record = try await OutboxMessageRecord.find(id, on: database) else {
            return
        }
        record.attempts = attempts
        record.availableAt = availableAt
        record.lastError = error
        try await record.update(on: database)
    }

    @discardableResult
    func deletePublished(publishedBefore cutoff: Date, limit: Int) async throws -> Int {
        // Oldest published rows first, so a limited batch reliably makes progress
        // instead of repeatedly revisiting newer rows and never reaching the old
        // ones (which would stall cleanup and grow the table unboundedly).
        let candidates = try await OutboxMessageRecord.query(on: database)
            .filter(\.$status == OutboxMessage.Status.published.rawValue)
            .filter(\.$publishedAt < cutoff)
            .sort(\.$publishedAt, .ascending)
            .limit(limit)
            .all()

        let ids = candidates.compactMap(\.id)
        guard !ids.isEmpty else { return 0 }

        try await OutboxMessageRecord.query(on: database)
            .filter(\.$id ~~ ids)
            .delete()
        return ids.count
    }
}
