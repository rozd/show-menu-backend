import Foundation
import Testing
import Logging
import Fluent
@testable import ShowMenuBackend

// MARK: - Fixtures
//
// This suite runs against the *real* store adapter — `FluentUnitOfWork` over a
// SQLite database, with the production `FluentIdempotencyStore` bound to the
// transaction the unit of work hands out. Nothing here is simulated: the
// statements run in one real transaction, so if the idempotency record ever
// stopped sharing the command's transaction, these tests would fail.

private struct AtomicCommand: Command {
    struct Payload: Codable, Sendable { let value: String }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "atomic")
}

private struct AtomicResult: Codable, Sendable, Equatable { let ok: Bool }

/// Writes a "work" row through the *same* transaction the idempotency record
/// uses, then optionally fails — modelling a command whose own persistence
/// shares the transaction.
private struct WorkCommandHandler: IdempotentCommandHandler {
    typealias Params = AtomicCommand
    typealias Result = AtomicResult

    let unitOfWork: any UnitOfWork
    let idempotency: IdempotencyComponents
    /// Throw from the work itself, before the transaction ever reaches commit.
    let throwAfterWrite: Bool
    /// Point the work row at a non-existent parent. The deferred foreign key
    /// makes `COMMIT` fail — i.e. *after* the record has been written.
    let conflictAtCommit: Bool

    struct WorkError: Error {}

    func perform(_ command: AtomicCommand, in context: any UnitOfWorkContext) async throws -> AtomicResult {
        let transaction = context.transaction as! FluentTransaction
        try await writeAtomicityWorkRow(
            id: command.payload.value,
            parent: conflictAtCommit ? "no-such-parent" : nil,
            through: transaction
        )
        if throwAfterWrite { throw WorkError() }
        return AtomicResult(ok: true)
    }
}

// MARK: - Suite

@Suite("Idempotency atomicity (same transaction)")
struct IdempotencyAtomicityTests {

    private let config = IdempotencyConfiguration.default

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT(
        database: any Fluent.Database,
        throwAfterWrite: Bool = false,
        conflictAtCommit: Bool = false
    ) -> WorkCommandHandler {
        let logger = makeLogger()
        let ttl = config.ttl
        return WorkCommandHandler(
            unitOfWork: FluentUnitOfWork(
                database: database,
                dispatcher: SpyDomainEventDispatcher(),
                outbox: Outbox(),
                logger: logger
            ),
            idempotency: IdempotencyComponents(
                storeFactory: { ctx in
                    // Bound to the command's transaction — the property under test.
                    FluentIdempotencyStore(
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

    private func recordId(forKey key: String) throws -> String {
        config.scope.recordId(
            key: try IdempotencyKey(key),
            commandType: String(reflecting: AtomicCommand.self),
            principalId: nil
        )
    }

    /// Probes the *committed* idempotency slot through a fresh direct transaction:
    /// `.replay` means a record survived the commit, `.proceed` means none did.
    /// Asserting through the store's own contract keeps the test independent of
    /// how the store lays its record out.
    private func committedReservation(
        _ database: any Fluent.Database,
        key: String,
        payload: AtomicCommand.Payload
    ) async throws -> IdempotencyReservation {
        let store = FluentIdempotencyStore(
            transaction: .direct(database: database),
            ttl: config.ttl,
            logger: makeLogger()
        )
        return try await store.reserve(
            id: try recordId(forKey: key),
            fingerprint: try RequestFingerprint(payload: payload)
        )
    }

    // MARK: - Success: record + work commit together

    @Test("record and work commit in the same transaction")
    func recordAndWorkCommitTogether() async throws {
        try await withSQLiteDatabase { database, _ in
            try await createAtomicityTables(on: database)
            let sut = self.makeSUT(database: database)
            let payload = AtomicCommand.Payload(value: "X")

            let result = try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("commit")) {
                try await sut.handle(AtomicCommand(payload: payload))
            }

            #expect(result == AtomicResult(ok: true))

            // Both the work write AND the idempotency record are now committed.
            let workExists = try await atomicityWorkRowExists(id: "X", on: database)
            #expect(workExists)
            let reservation = try await self.committedReservation(database, key: "commit", payload: payload)
            guard case .replay = reservation else {
                Issue.record("Expected a committed record to replay, got \(reservation)")
                return
            }
        }
    }

    // MARK: - Work failure: nothing persists (no marked-but-not-done)

    @Test("when the work fails, neither the work nor an idempotency record persists")
    func workFailureRollsBackTogether() async throws {
        try await withSQLiteDatabase { database, _ in
            try await createAtomicityTables(on: database)
            let sut = self.makeSUT(database: database, throwAfterWrite: true)
            let payload = AtomicCommand.Payload(value: "Y")

            await #expect(throws: WorkCommandHandler.WorkError.self) {
                try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("fail")) {
                    try await sut.handle(AtomicCommand(payload: payload))
                }
            }

            // Rolled back: the work write is gone, and crucially no record was left
            // behind — so the key is free for a genuine retry.
            let workExists = try await atomicityWorkRowExists(id: "Y", on: database)
            #expect(workExists == false)
            let reservation = try await self.committedReservation(database, key: "fail", payload: payload)
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
            // — *after* the idempotency record has been written into the same
            // transaction. That is the window this test exists for.
            let sut = self.makeSUT(database: database, conflictAtCommit: true)
            let payload = AtomicCommand.Payload(value: "Z")

            await #expect(throws: (any Error).self) {
                try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("commit-fail")) {
                    try await sut.handle(AtomicCommand(payload: payload))
                }
            }

            // The work write and the record were discarded together: no
            // "done-but-not-marked" and no "marked-but-not-done".
            let workExists = try await atomicityWorkRowExists(id: "Z", on: database)
            #expect(workExists == false)
            let reservation = try await self.committedReservation(database, key: "commit-fail", payload: payload)
            guard case .proceed = reservation else {
                Issue.record("Expected no committed record, got \(reservation)")
                return
            }
        }
    }
}
