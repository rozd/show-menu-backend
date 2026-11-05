import Foundation
import Testing
@testable import VaporFirebaseBackendApp

// MARK: - Test fixtures

private struct TestCommand: Command {
    struct Payload: Codable, Sendable, Equatable {
        let value: String
    }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "test")
}

/// A `CommandHandler` spy: counts how many times the *work* actually runs, and
/// can be configured to return void or throw.
private final class SpyCommandHandler: InboxedCommandHandler, @unchecked Sendable {
    typealias Params = TestCommand
    typealias Result = Void

    let unitOfWork: any UnitOfWork
    let inbox: InboxComponents
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }

    init(
        unitOfWork: any UnitOfWork = StubUnitOfWork(),
        inbox: InboxComponents
    ) {
        self.unitOfWork = unitOfWork
        self.inbox = inbox
    }

    func perform(_ command: TestCommand, in context: any UnitOfWorkContext) async throws -> Void {
        lock.withLock { _callCount += 1 }
    }
}

@Suite("InboxedCommandHandler")
struct InboxedCommandHandlerTests {

    private func makeSUT(
        store: StubInboxStore
    ) -> SpyCommandHandler {
        SpyCommandHandler(
            inbox: InboxComponents(
                storeFactory: { _ in store }
            )
        )
    }

    /// The record id the mixin computes for `eventId` under the default consumer.
    private func recordId(forEventId eventId: UUID) -> String {
        InboxRecordId.derive(
            consumer: String(reflecting: TestCommand.self),
            eventId: eventId
        )
    }

    private func command(_ value: String) -> TestCommand {
        TestCommand(payload: .init(value: value))
    }

    // MARK: - New event executes once and stores the marker

    @Test("new event runs the work once and stores the marker")
    func newEventRunsOnceAndStores() async throws {
        let store = StubInboxStore()
        let sut = makeSUT(store: store)
        let eventId = UUID()

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(command("hello"))
        }

        #expect(sut.callCount == 1)
        let id = recordId(forEventId: eventId)
        #expect(await store.entry(id: id) != nil)
    }

    // MARK: - Duplicate silently skips execution

    @Test("duplicate event skips execution silently")
    func duplicateEventSkips() async throws {
        let store = StubInboxStore()
        let sut = makeSUT(store: store)
        let eventId = UUID()

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(command("once"))
        }
        // Same event id → must skip, not re-execute.
        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(command("again"))
        }

        #expect(sut.callCount == 1)   // work ran exactly once
        #expect(await store.count == 1)   // one marker
    }

    // MARK: - No event id → transparent pass-through

    @Test("request without an event id runs normally and stores nothing")
    func noEventIdPassesThrough() async throws {
        let store = StubInboxStore()
        let sut = makeSUT(store: store)

        // No RequestContext.integrationEventId set.
        try await sut.handle(command("plain"))

        #expect(sut.callCount == 1)
        #expect(await store.count == 0)   // no record written
    }

    // MARK: - Expired record is re-executed (TTL)

    @Test("expired record is treated as absent and the work runs again")
    func expiredRecordReExecutes() async throws {
        let store = StubInboxStore()
        let sut = makeSUT(store: store)
        let eventId = UUID()
        let id = recordId(forEventId: eventId)
        // A processed record whose TTL already elapsed.
        await store.seedProcessed(id: id, expiresAt: Date(timeIntervalSince1970: 0))

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(command("body"))
        }

        #expect(sut.callCount == 1)  // re-executed, not skipped
    }

    // MARK: - Two different consumers of one event each process once

    @Test("two different consumers of one event each process once")
    func twoConsumersProcessOneEventOnce() async throws {
        // Define a second command type to distinguish the consumer.
        struct OtherCommand: Command {
            struct Payload: Codable, Sendable, Equatable {
                let value: String
            }
            let payload: Payload
            let metadata: CommandMetadata = CommandMetadata(correlationId: "test")
        }

        // Second spy handler over OtherCommand.
        final class OtherSpyHandler: InboxedCommandHandler, @unchecked Sendable {
            typealias Params = OtherCommand
            typealias Result = Void

            let unitOfWork: any UnitOfWork
            let inbox: InboxComponents
            private let lock = NSLock()
            private var _callCount = 0

            var callCount: Int { lock.withLock { _callCount } }

            init(unitOfWork: any UnitOfWork = StubUnitOfWork(), inbox: InboxComponents) {
                self.unitOfWork = unitOfWork
                self.inbox = inbox
            }

            func perform(_ command: OtherCommand, in context: any UnitOfWorkContext) async throws -> Void {
                lock.withLock { _callCount += 1 }
            }
        }

        let store = StubInboxStore()
        let eventId = UUID()

        // First consumer (TestCommand).
        let sut1 = makeSUT(store: store)
        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut1.handle(command("first"))
        }

        // Second consumer (OtherCommand).
        let sut2 = OtherSpyHandler(
            inbox: InboxComponents(
                storeFactory: { _ in store }
            )
        )
        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut2.handle(OtherCommand(payload: .init(value: "second")))
        }

        // Both ran once; distinct record ids because consumer type differs.
        #expect(sut1.callCount == 1)
        #expect(sut2.callCount == 1)
        #expect(await store.count == 2)   // One marker per consumer
    }

    // MARK: - Expired slot carries the overwrite ticket

    @Test("an expired record yields a proceed ticket marked overwriteExpired")
    func expiredRecordYieldsOverwriteTicket() async throws {
        // Covered via the stub (a FirestoreInboxStore needs a live Firestore).
        let store = StubInboxStore()
        await store.seedProcessed(id: "slot", expiresAt: Date(timeIntervalSince1970: 0))

        let reservation = try await store.reserve(id: "slot")

        guard case .proceed(let ticket) = reservation else {
            Issue.record("Expected proceed, got \(reservation)")
            return
        }
        #expect(ticket.overwriteExpired)
    }

    // MARK: - Record id derivation

    @Test("record id is deterministic and differs per consumer and per event")
    func recordIdDerivation() {
        let event = UUID()
        let a = InboxRecordId.derive(consumer: "A", eventId: event)
        #expect(a == InboxRecordId.derive(consumer: "A", eventId: event))
        #expect(a != InboxRecordId.derive(consumer: "B", eventId: event))
        #expect(a != InboxRecordId.derive(consumer: "A", eventId: UUID()))
        #expect(a.count == 64)  // hex SHA-256, path-safe
    }
}
