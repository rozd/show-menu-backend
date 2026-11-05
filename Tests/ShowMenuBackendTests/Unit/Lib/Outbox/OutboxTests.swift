import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

// MARK: - Test fixtures

/// A minimal integration event used across the outbox tests.
private struct OutboxTestEvent: IntegrationEvent {
    static let kind = "test.outbox.event"

    let id: UUID
    let metadata: IntegrationEventMetadata
    let value: String

    init(id: UUID = UUID(), value: String, correlationId: TraceID? = nil, occurredAt: Date = .now) {
        self.id = id
        self.value = value
        self.metadata = IntegrationEventMetadata(
            origin: "Test",
            correlationId: correlationId,
            occurredAt: occurredAt
        )
    }
}

private enum OutboxTestError: Error { case publishFailed }

private func makeLogger() -> Logger {
    Logger(label: "outbox-test", factory: { _ in CapturingLogHandler() })
}

/// A coder backed by a private registry with `OutboxTestEvent` registered, so
/// decode (relay side) round-trips without touching the shared registry.
private func makeCoder() async -> JSONIntegrationEventCoder {
    let registry = IntegrationEventRegistry()
    await registry.register(OutboxTestEvent.self)
    return JSONIntegrationEventCoder(registry: registry)
}

private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

// MARK: - In-transaction write side

@Suite("Outbox — recording channel")
struct OutboxIntegrationEventChannelTests {

    @Test("record encodes the event and appends a pending message")
    func record_appendsPending() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()
        let channel = OutboxIntegrationEventChannel(store: store, coder: coder, now: { fixedNow })

        let event = OutboxTestEvent(value: "hello", correlationId: "corr-1")
        try await channel.record(event)

        let appended = await store.appended
        #expect(appended.count == 1)

        let message = try #require(appended.first)
        #expect(message.id == event.id)
        #expect(message.kind == OutboxTestEvent.kind)
        #expect(message.status == .pending)
        #expect(message.sequence == 0)
        #expect(message.attempts == 0)
        #expect(message.createdAt == fixedNow)
        #expect(message.availableAt == fixedNow)
        #expect(message.metadata.correlationId == "corr-1")

        // The stored payload round-trips back to the original event.
        let decoded = try await coder.decode(message.envelope) as? OutboxTestEvent
        #expect(decoded?.value == "hello")
    }

    @Test("sequence increments across records within one transaction")
    func record_sequenceIncrements() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()
        let channel = OutboxIntegrationEventChannel(store: store, coder: coder, now: { fixedNow })

        try await channel.record(OutboxTestEvent(value: "a"))
        try await channel.record(OutboxTestEvent(value: "b"))
        try await channel.record(OutboxTestEvent(value: "c"))

        let sequences = await store.appended.map(\.sequence)
        #expect(sequences == [0, 1, 2])
    }

    @Test("a store append failure propagates so the transaction can roll back")
    func record_appendFailurePropagates() async throws {
        let store = InMemoryOutboxStore()
        await store.setFailAppend(true)
        let coder = await makeCoder()
        let channel = OutboxIntegrationEventChannel(store: store, coder: coder, now: { fixedNow })

        await #expect(throws: InMemoryOutboxStore.Failure.self) {
            try await channel.record(OutboxTestEvent(value: "x"))
        }
    }
}

// MARK: - Relay

@Suite("Outbox — relay")
struct OutboxRelayTests {

    private func message(_ value: String, sequence: Int, at: Date, coder: any IntegrationEventCoder) throws -> OutboxMessage {
        try OutboxMessage.pending(from: OutboxTestEvent(value: value), sequence: sequence, at: at, coder: coder)
    }

    @Test("drain publishes pending messages in FIFO order and marks them published")
    func drain_publishesAndMarks() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()

        let m0 = try message("a", sequence: 0, at: fixedNow, coder: coder)
        let m1 = try message("b", sequence: 1, at: fixedNow, coder: coder)
        let m2 = try message("c", sequence: 2, at: fixedNow, coder: coder)
        // Seed out of insertion order; the relay must still publish a, b, c.
        await store.seed(m2)
        await store.seed(m0)
        await store.seed(m1)

        let spy = SpyIntegrationEventChannel()
        let relay = Outbox(coder: coder).relay(store: store, channel: spy, logger: makeLogger(), now: { fixedNow })

        let summary = await relay.drain()
        #expect(summary.published == 3)
        #expect(summary.failed == 0)

        let events = await spy.publishedEvents
        let values = events.compactMap { $0 as? OutboxTestEvent }.map(\.value)
        #expect(values == ["a", "b", "c"])

        for message in [m0, m1, m2] {
            let stored = await store.get(message.id)
            #expect(stored?.status == .published)
            #expect(stored?.publishedAt == fixedNow)
        }
    }

    @Test("a publish failure leaves the message pending for retry with backoff (at-least-once)")
    func drain_publishFailureRetains() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()
        let message = try message("x", sequence: 0, at: fixedNow, coder: coder)
        await store.seed(message)

        let relay = OutboxRelay(
            store: store,
            publish: { _ in throw OutboxTestError.publishFailed },
            coder: coder,
            backoff: .exponential(initial: 10, multiplier: 2, cap: 300),
            batchSize: 100,
            retention: 3600,
            now: { fixedNow },
            logger: makeLogger()
        )

        let summary = await relay.drain()
        #expect(summary.published == 0)
        #expect(summary.failed == 1)

        let after = try #require(await store.get(message.id))
        #expect(after.status == .pending) // not lost — retried later
        #expect(after.attempts == 1)
        #expect(after.availableAt == fixedNow.addingTimeInterval(10)) // base * 2^0
        #expect(after.lastError != nil)
    }

    @Test("a failed message is skipped until its backoff elapses, then republished")
    func drain_retryAfterBackoff() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()
        let message = try message("x", sequence: 0, at: fixedNow, coder: coder)
        await store.seed(message)

        // First pass fails, scheduling a retry at fixedNow + 10.
        let failing = OutboxRelay(
            store: store,
            publish: { _ in throw OutboxTestError.publishFailed },
            coder: coder,
            backoff: .exponential(initial: 10, multiplier: 2, cap: 300),
            batchSize: 100,
            retention: 3600,
            now: { fixedNow },
            logger: makeLogger()
        )
        _ = await failing.drain()

        let spy = SpyIntegrationEventChannel()

        // Not yet due at fixedNow → nothing republished.
        let early = Outbox(coder: coder).relay(store: store, channel: spy, logger: makeLogger(), now: { fixedNow })
        let earlySummary = await early.drain()
        #expect(earlySummary.published == 0)
        #expect(await store.get(message.id)?.status == .pending)

        // Due at fixedNow + 20 → republished and marked.
        let later = Outbox(coder: coder).relay(
            store: store, channel: spy, logger: makeLogger(), now: { fixedNow.addingTimeInterval(20) }
        )
        let laterSummary = await later.drain()
        #expect(laterSummary.published == 1)
        #expect(await store.get(message.id)?.status == .published)

        let events = await spy.publishedEvents
        #expect(events.compactMap { $0 as? OutboxTestEvent }.map(\.value) == ["x"])
    }

    @Test("drain prunes published rows older than the retention window")
    func drain_cleanup() async throws {
        let store = InMemoryOutboxStore()
        let coder = await makeCoder()

        // Old published row (well past retention).
        var old = try message("old", sequence: 0, at: fixedNow.addingTimeInterval(-10_000), coder: coder)
        old.status = .published
        old.publishedAt = fixedNow.addingTimeInterval(-10_000)
        // Recently published row (within retention).
        var recent = try message("recent", sequence: 1, at: fixedNow.addingTimeInterval(-100), coder: coder)
        recent.status = .published
        recent.publishedAt = fixedNow.addingTimeInterval(-100)
        // A pending row that is not yet due, so it is untouched by this drain.
        var pendingLater = try message("later", sequence: 2, at: fixedNow, coder: coder)
        pendingLater.availableAt = fixedNow.addingTimeInterval(10_000)

        await store.seed(old)
        await store.seed(recent)
        await store.seed(pendingLater)

        let spy = SpyIntegrationEventChannel()
        // retention 3600s → cutoff = fixedNow - 3600; only `old` is older.
        let relay = Outbox(retention: 3600, coder: coder).relay(
            store: store, channel: spy, logger: makeLogger(), now: { fixedNow }
        )

        let summary = await relay.drain()
        #expect(summary.deleted == 1)
        #expect(await store.get(old.id) == nil)
        #expect(await store.get(recent.id) != nil)
        #expect(await store.get(pendingLater.id) != nil)
    }
}

// MARK: - Transactional recording (atomicity)

@Suite("Outbox — transactional recording")
struct OutboxUnitOfWorkTests {

    @Test("events recorded inside a unit of work commit with it")
    func recordsCommitOnSuccess() async throws {
        let uow = StubUnitOfWork()

        try await uow.execute { ctx in
            try await ctx.outbox.record(OutboxTestEvent(value: "ok"))
        }

        let committed = await uow.committedOutbox.appended
        #expect(committed.count == 1)
        #expect(committed.first?.kind == OutboxTestEvent.kind)
    }

    @Test("events recorded inside a unit of work roll back when it fails")
    func recordsRollBackOnFailure() async {
        let uow = StubUnitOfWork()

        await #expect(throws: OutboxTestError.self) {
            try await uow.execute { ctx in
                try await ctx.outbox.record(OutboxTestEvent(value: "doomed"))
                throw OutboxTestError.publishFailed // abort the transaction after recording
            }
        }

        let committed = await uow.committedOutbox.appended
        #expect(committed.isEmpty) // no committed state ⇒ no orphaned outbox row
    }
}

// MARK: - Firestore model

@Suite("Outbox — Firestore model")
struct OutboxMessageModelTests {

    private func makeMessage() async throws -> OutboxMessage {
        let coder = await makeCoder()
        return try OutboxMessage.pending(
            from: OutboxTestEvent(value: "v"), sequence: 0, at: fixedNow, coder: coder
        )
    }

    @Test("a valid model round-trips back to its message")
    func roundTrip() async throws {
        let message = try await makeMessage()
        let restored = try OutboxMessageModel(message).toMessage()
        #expect(restored.id == message.id)
        #expect(restored.kind == message.kind)
        #expect(restored.payload == message.payload)
        #expect(restored.sequence == message.sequence)
    }

    @Test("a malformed document id fails fast instead of inventing an identity")
    func malformedIdThrows() async throws {
        var model = try await OutboxMessageModel(makeMessage())
        model.id = "not-a-uuid"
        #expect(throws: OutboxMessageModel.DecodingError.self) {
            _ = try model.toMessage()
        }
    }
}
