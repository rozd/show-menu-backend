import Foundation
import Testing
import Logging
import Fluent
@testable import ShowMenuBackend

// MARK: - Fixtures
//
// This suite runs against the *real* store adapter — `FluentUnitOfWork` over a
// SQLite database, with the production `FluentInboxStore` bound to the
// transaction the unit of work hands out. Nothing here is simulated: the
// statements run in one real transaction, so if the inbox record ever stopped
// sharing the handler's transaction, these tests would fail.

private struct AtomicCommand: Command {
    struct Payload: Codable, Sendable { let value: String }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "atomic")
}

/// Writes a "work" row through the *same* transaction the inbox record uses,
/// then optionally fails — modelling a handler whose own persistence shares the
/// transaction.
private struct WorkHandler: InboxedCommandHandler {
    typealias Params = AtomicCommand
    typealias Result = Void

    let unitOfWork: any UnitOfWork
    let inbox: InboxComponents
    /// Throw from the work itself, before the transaction ever reaches commit.
    let throwAfterWrite: Bool
    /// Point the work row at a non-existent parent. The deferred foreign key
    /// makes `COMMIT` fail — i.e. *after* the record has been written.
    let conflictAtCommit: Bool

    struct WorkError: Error {}

    func perform(_ command: AtomicCommand, in context: any UnitOfWorkContext) async throws -> Void {
        let transaction = context.transaction as! FluentTransaction
        try await writeAtomicityWorkRow(
            id: command.payload.value,
            parent: conflictAtCommit ? "no-such-parent" : nil,
            through: transaction
        )
        if throwAfterWrite { throw WorkError() }
    }
}

// MARK: - Suite

@Suite("Inbox Atomicity (same transaction)")
struct InboxAtomicityTests {

    private let config = InboxConfiguration.default

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT(
        database: any Fluent.Database,
        throwAfterWrite: Bool = false,
        conflictAtCommit: Bool = false
    ) -> WorkHandler {
        let logger = makeLogger()
        let ttl = config.ttl
        return WorkHandler(
            unitOfWork: FluentUnitOfWork(
                database: database,
                dispatcher: SpyDomainEventDispatcher(),
                outbox: Outbox(),
                logger: logger
            ),
            inbox: InboxComponents(
                storeFactory: { ctx in
                    // Bound to the handler's transaction — the property under test.
                    FluentInboxStore(
                        transaction: ctx.transaction as! FluentTransaction,
                        ttl: ttl,
                        logger: logger
                    )
                },
                configuration: config
            ),
            throwAfterWrite: throwAfterWrite,
            conflictAtCommit: conflictAtCommit
        )
    }

    // MARK: Probes

    private func recordId(forEventId eventId: UUID) -> String {
        InboxRecordId.derive(
            consumer: String(reflecting: AtomicCommand.self),
            eventId: eventId
        )
    }

    /// Probes the *committed* inbox slot through a fresh direct transaction:
    /// `.alreadyProcessed` means a record survived the commit, `.proceed` means
    /// none did. Asserting through the store's own contract keeps the test
    /// independent of how the store lays its record out.
    private func committedReservation(
        _ database: any Fluent.Database,
        eventId: UUID
    ) async throws -> InboxReservation {
        let store = FluentInboxStore(
            transaction: .direct(database: database),
            ttl: config.ttl,
            logger: makeLogger()
        )
        return try await store.reserve(id: recordId(forEventId: eventId))
    }

    // MARK: - Success: record + work commit together

    @Test("record and work commit in the same transaction")
    func recordAndWorkCommitTogether() async throws {
        try await withSQLiteDatabase { database, _ in
            try await createAtomicityTables(on: database)
            let sut = self.makeSUT(database: database)
            let eventId = UUID()

            try await RequestContext.$integrationEventId.withValue(eventId) {
                try await sut.handle(AtomicCommand(payload: .init(value: "X")))
            }

            // Both the work write AND the inbox record are now committed.
            let workExists = try await atomicityWorkRowExists(id: "X", on: database)
            #expect(workExists)
            let reservation = try await self.committedReservation(database, eventId: eventId)
            guard case .alreadyProcessed = reservation else {
                Issue.record("Expected a committed record to report alreadyProcessed, got \(reservation)")
                return
            }
        }
    }

    // MARK: - Work failure: nothing persists (no marked-but-not-done)

    @Test("when the work fails, neither the work nor an inbox record persists")
    func workFailureRollsBackTogether() async throws {
        try await withSQLiteDatabase { database, _ in
            try await createAtomicityTables(on: database)
            let sut = self.makeSUT(database: database, throwAfterWrite: true)
            let eventId = UUID()

            await #expect(throws: WorkHandler.WorkError.self) {
                try await RequestContext.$integrationEventId.withValue(eventId) {
                    try await sut.handle(AtomicCommand(payload: .init(value: "Y")))
                }
            }

            // Rolled back: the work write is gone, and crucially no record was left
            // behind — so the event is free for a genuine retry.
            let workExists = try await atomicityWorkRowExists(id: "Y", on: database)
            #expect(workExists == false)
            let reservation = try await self.committedReservation(database, eventId: eventId)
            guard case .proceed = reservation else {
                Issue.record("Expected no committed record, got \(reservation)")
                return
            }
        }
    }

    // MARK: - Commit failure: record + work roll back together

    @Test("when the commit fails after storing, record and work roll back together")
    func commitFailureRollsBackTogether() async throws {
        try await withSQLiteDatabase { database, _ in
            try await createAtomicityTables(on: database)
            // The work row points at a parent that does not exist. The foreign key
            // is deferred, so every statement succeeds and `COMMIT` is what fails
            // — *after* the inbox record has been written into the same
            // transaction. That is the window this test exists for.
            let sut = self.makeSUT(database: database, conflictAtCommit: true)
            let eventId = UUID()

            await #expect(throws: (any Error).self) {
                try await RequestContext.$integrationEventId.withValue(eventId) {
                    try await sut.handle(AtomicCommand(payload: .init(value: "Z")))
                }
            }

            // The work write and the record were discarded together: no
            // "done-but-not-marked" and no "marked-but-not-done".
            let workExists = try await atomicityWorkRowExists(id: "Z", on: database)
            #expect(workExists == false)
            let reservation = try await self.committedReservation(database, eventId: eventId)
            guard case .proceed = reservation else {
                Issue.record("Expected no committed record, got \(reservation)")
                return
            }
        }
    }
}
