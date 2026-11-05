//
//  FirestoreOutboxStore.swift
//  ShowMenuBackend
//
//  Firestore binding of the transactional outbox.
//

import Foundation
import FirestoreAPI
import GRPCCore
import Logging

// MARK: - Store

/// Firestore-backed ``OutboxStore``.
///
/// The **write side** (`append`) runs through a `FirestoreTransaction` — the same
/// one the ``Repository`` uses for the command's state change — so the row is
/// buffered as part of that transaction and flushed atomically at commit (or
/// discarded on rollback). This is how the outbox enlists in the Unit of Work:
/// it never opens its own transaction.
///
/// The **relay side** constructs this store with `.direct(firestore:)` to read,
/// mark, and prune rows outside any command transaction.
///
/// Mark/prune use a read-modify-write through the proven `Encodable` `set` path
/// rather than partial field updates — simple and store-agnostic; a production
/// relay could optimize to field-level updates.
struct FirestoreOutboxStore: OutboxStore {

    let transaction: FirestoreTransaction
    let collection: String
    let logger: Logger

    init(transaction: FirestoreTransaction, collection: String = "outbox", logger: Logger) {
        self.transaction = transaction
        self.collection = collection
        self.logger = logger
    }

    private var collectionRef: CollectionReference {
        transaction.collection(collection)
    }

    private func document(_ id: String) -> DocumentReference {
        collectionRef.document(id)
    }

    // MARK: Write side

    func append(_ message: OutboxMessage) async throws {
        let model = OutboxMessageModel(message)
        logger.debug("Appending outbox message", metadata: [
            "collection": .string(collection),
            "messageId": .string(message.id.uuidString),
            "kind": .string(message.kind)
        ])
        do {
            // A buffered `create` on the active transaction — atomic with the
            // command's state change.
            try await transaction.create(documentReference: document(message.id.uuidString), from: model)
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }

    // MARK: Relay side

    func pending(limit: Int, now: Date) async throws -> [OutboxMessage] {
        // Equality-only query (`status == pending`) needs no composite index.
        // Over-fetch, then filter "due" and order client-side — fine for the
        // template's expected small, frequently-drained outbox. Production with a
        // large backlog should add a composite index and order/limit server-side.
        let query = collectionRef
            .where(field: OutboxMessageModel.Field.status, isEqualTo: OutboxMessage.Status.pending.rawValue)
            .limit(to: max(limit, limit * 4))
        do {
            let models = try await transaction.getDocuments(OutboxMessageModel.self, query: query)
            let messages: [OutboxMessage] = models.compactMap { model in
                do {
                    return try model.toMessage()
                } catch {
                    logger.warning("Outbox message decode failed; skipping", metadata: [
                        "messageId": .string(model.id),
                        "error": .string(String(describing: error))
                    ])
                    return nil
                }
            }
            let due: [OutboxMessage] = messages.filter { $0.availableAt <= now }
            let ordered: [OutboxMessage] = due.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sequence < rhs.sequence
            }
            return Array(ordered.prefix(limit))
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }

    func markPublished(id: UUID, at: Date) async throws {
        let ref = document(id.uuidString)
        do {
            guard var model = try await transaction.getDocument(OutboxMessageModel.self, documentReference: ref) else {
                return // already gone — idempotent
            }
            model.status = OutboxMessage.Status.published.rawValue
            model.publishedAt = Timestamp(at)
            model.lastError = nil
            try await transaction.set(documentReference: ref, from: model)
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }

    func recordFailure(id: UUID, attempts: Int, availableAt: Date, error: String) async throws {
        let ref = document(id.uuidString)
        do {
            guard var model = try await transaction.getDocument(OutboxMessageModel.self, documentReference: ref) else {
                return
            }
            model.attempts = attempts
            model.availableAt = Timestamp(availableAt)
            model.lastError = error
            try await transaction.set(documentReference: ref, from: model)
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }

    @discardableResult
    func deletePublished(publishedBefore cutoff: Date, limit: Int) async throws -> Int {
        do {
            // Order by `publishedAt` ascending so the OLDEST published rows come
            // first: those are the ones past the cutoff, so a limited batch reliably
            // makes progress instead of repeatedly fetching newer rows and never
            // reaching the old ones (which would stall cleanup and grow the
            // collection). Equality + order-by needs a composite index in production
            // Firestore: `status ASC, publishedAt ASC`.
            let query = collectionRef
                .where(field: OutboxMessageModel.Field.status, isEqualTo: OutboxMessage.Status.published.rawValue)
                .order(by: OutboxMessageModel.Field.publishedAt, descending: false)
                .limit(to: limit)
            let models = try await transaction.getDocuments(OutboxMessageModel.self, query: query)
            var deleted = 0
            for model in models {
                guard let publishedAt = Date(model.publishedAt), publishedAt < cutoff else { continue }
                try await transaction.delete(documentReference: document(model.id))
                deleted += 1
            }
            return deleted
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }
}

// MARK: - Firestore Model

/// Firestore Codable representation of an ``OutboxMessage``.
///
/// `payload` is stored base64-encoded (transport-encoder-agnostic and human-
/// inspectable); dates are Firestore `Timestamp`s. `kind`/`origin` are kept as
/// top-level fields for queryability and ops visibility.
struct OutboxMessageModel: Codable, Sendable {

    enum Field {
        static let status = "status"
        static let publishedAt = "publishedAt"
    }

    @DocumentID
    var id: String
    let kind: String
    let payloadBase64: String
    let origin: String
    let correlationId: String?
    let occurredAt: Timestamp?
    let sequence: Int
    var status: String
    let createdAt: Timestamp?
    var publishedAt: Timestamp?
    var attempts: Int
    var availableAt: Timestamp?
    var lastError: String?
}

extension OutboxMessageModel {

    enum DecodingError: Error, Sendable {
        case malformedID(id: String)
        case malformedPayload(id: String)
        case missingTimestamps(id: String)
    }

    init(_ message: OutboxMessage) {
        self.id = message.id.uuidString
        self.kind = message.kind
        self.payloadBase64 = message.payload.base64EncodedString()
        self.origin = message.metadata.origin
        self.correlationId = message.metadata.correlationId?.rawValue
        self.occurredAt = Timestamp(message.metadata.occurredAt)
        self.sequence = message.sequence
        self.status = message.status.rawValue
        self.createdAt = Timestamp(message.createdAt)
        self.publishedAt = message.publishedAt.map { Timestamp($0) }
        self.attempts = message.attempts
        self.availableAt = Timestamp(message.availableAt)
        self.lastError = message.lastError
    }

    func toMessage() throws -> OutboxMessage {
        guard let payload = Data(base64Encoded: payloadBase64) else {
            throw DecodingError.malformedPayload(id: id)
        }
        guard let createdAt = Date(createdAt), let availableAt = Date(availableAt) else {
            throw DecodingError.missingTimestamps(id: id)
        }
        guard let uuid = UUID(uuidString: id) else {
            throw DecodingError.malformedID(id: id)
        }
        let metadata = IntegrationEventMetadata(
            origin: origin,
            correlationId: correlationId.map { TraceID(stringLiteral: $0) },
            occurredAt: Date(occurredAt) ?? createdAt
        )
        return OutboxMessage(
            id: uuid,
            kind: kind,
            payload: payload,
            metadata: metadata,
            sequence: sequence,
            status: OutboxMessage.Status(rawValue: status) ?? .pending,
            createdAt: createdAt,
            publishedAt: Date(publishedAt),
            attempts: attempts,
            availableAt: availableAt,
            lastError: lastError
        )
    }
}
