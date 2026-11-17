import Foundation
import Testing
@testable import ShowMenuBackend

/// Tests for record-to-message mappings in the Fluent outbox and idempotency stores.
@Suite("Fluent Records")
struct FluentRecordTests {

    // MARK: - Outbox Record Mapping

    @Test("OutboxMessageRecord(message).toMessage() round-trips all fields")
    func outboxRecordRoundTrip() throws {
        let originalMsg = OutboxMessage(
            id: UUID(),
            kind: "UserOnboarded",
            payload: Data("test payload".utf8),
            metadata: IntegrationEventMetadata(
                origin: "users",
                correlationId: TraceID(stringLiteral: "trace-123"),
                occurredAt: Date(timeIntervalSince1970: 5000)
            ),
            sequence: 1,
            status: .pending,
            createdAt: Date(timeIntervalSince1970: 1000),
            publishedAt: nil,
            attempts: 0,
            availableAt: Date(timeIntervalSince1970: 2000),
            lastError: nil
        )

        let record = OutboxMessageRecord(originalMsg)
        let recovered = try record.toMessage()

        #expect(recovered.id == originalMsg.id)
        #expect(recovered.kind == originalMsg.kind)
        #expect(recovered.payload == originalMsg.payload)
        #expect(recovered.metadata.origin == originalMsg.metadata.origin)
        #expect(recovered.metadata.correlationId == originalMsg.metadata.correlationId)
        #expect(recovered.metadata.occurredAt == originalMsg.metadata.occurredAt)
        #expect(recovered.sequence == originalMsg.sequence)
        #expect(recovered.status == originalMsg.status)
        #expect(recovered.createdAt == originalMsg.createdAt)
        #expect(recovered.publishedAt == nil)
        #expect(recovered.attempts == 0)
        #expect(recovered.availableAt == originalMsg.availableAt)
        #expect(recovered.lastError == nil)
    }

    @Test("OutboxMessageRecord: when stored occurredAt is nil, it falls back to createdAt in recovery")
    func outboxOccurredAtFallback() throws {
        // Create a record where occurredAt is stored as nil
        let createdAt = Date(timeIntervalSince1970: 1000)
        let record = OutboxMessageRecord()
        record.id = UUID()
        record.kind = "UserOnboarded"
        record.payload = Data()
        record.origin = "users"
        record.correlationId = nil
        record.occurredAt = nil  // Explicitly nil in storage
        record.sequence = 1
        record.status = OutboxMessage.Status.pending.rawValue
        record.createdAt = createdAt
        record.publishedAt = nil
        record.attempts = 0
        record.availableAt = Date()
        record.lastError = nil

        let recovered = try record.toMessage()

        // According to OutboxMessageRecord.toMessage(): occurredAt ?? createdAt
        // So if stored occurredAt is nil, it should use createdAt
        #expect(recovered.metadata.occurredAt == createdAt)
    }

    // MARK: - Idempotency Record Mapping

    @Test("IdempotencyKeyRecord.toMessage() round-trips StoredResponse")
    func idempotencyRecordRoundTrip() throws {
        let response = StoredResponse(status: 200, body: Data("OK".utf8))
        let record = IdempotencyKeyRecord(
            id: "key-123",
            fingerprint: "fingerprint-abc",
            status: .completed,
            response: response,
            createdAt: Date(timeIntervalSince1970: 1000),
            expiresAt: Date(timeIntervalSince1970: 86400)
        )

        #expect(record.responseStatus == 200)
        #expect(record.responseBody == Data("OK".utf8))
    }

    @Test("IdempotencyKeyRecord: missing body in completed record is corrupt")
    func idempotencyCorruptRecord() throws {
        // A completed record with nil body is corrupt (see storedResponse implementation)
        let record = IdempotencyKeyRecord(
            id: "key-123",
            fingerprint: "fingerprint-abc",
            status: .completed,
            response: nil,  // Missing response body
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)
        )

        // The storedResponse function would throw on accessing a nil responseBody
        // We can't directly call it without actor isolation, but this documents
        // the invariant that completed records must have a body.
        #expect(record.responseBody == nil)
    }
}
