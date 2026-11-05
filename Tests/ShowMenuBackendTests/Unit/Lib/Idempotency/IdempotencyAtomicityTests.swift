import Foundation
import Testing
@testable import ShowMenuBackend

// MARK: - A transactional in-memory "transaction"
//
// Simulates one Firestore transaction: writes are *staged* (pending) and only
// become visible (committed) when the UnitOfWork commits; any failure discards
// the pending set. Both the command's work and the idempotency store write into
// the *same* buffer, so we can assert they commit / roll back together.

private actor RecordingTransaction {
    private(set) var committed: [String: String] = [:]
    private var pending: [String: String] = [:]

    func stage(_ key: String, _ value: String) { pending[key] = value }
    func read(_ key: String) -> String? { pending[key] ?? committed[key] }
    func commit() { committed.merge(pending) { _, new in new }; pending.removeAll() }
    func rollback() { pending.removeAll() }
}

private struct RecordingContext: UnitOfWorkContext {
    let transaction: RecordingTransaction
    let collector: any DomainEventCollector
    /// Unused here — this suite is about the idempotency record and the command's
    /// writes committing together, not about outbox recording.
    let outbox = OutboxIntegrationEventChannel(store: InMemoryOutboxStore())
}

private final class RecordingUnitOfWork: UnitOfWork, @unchecked Sendable {
    typealias Context = RecordingContext

    let dispatcher: any DomainEventDispatcher = SpyDomainEventDispatcher()
    let tx: RecordingTransaction
    /// When true, the transaction fails at commit *after* the work has run and the
    /// record has been staged — exercising "both roll back together".
    let failAtCommit: Bool

    struct CommitFailure: Error {}

    init(tx: RecordingTransaction, failAtCommit: Bool = false) {
        self.tx = tx
        self.failAtCommit = failAtCommit
    }

    func execute<R: Sendable>(
        _ work: @escaping @Sendable (RecordingContext) async throws -> R
    ) async throws -> R {
        let ctx = RecordingContext(transaction: tx, collector: InMemoryDomainEventCollector())
        do {
            let result = try await work(ctx)
            if failAtCommit {
                await tx.rollback()
                throw CommitFailure()
            }
            await tx.commit()
            return result
        } catch {
            await tx.rollback()
            throw error
        }
    }
}

/// An ``IdempotencyStore`` that reads/writes the shared `RecordingTransaction`,
/// so its record is part of the same atomic unit as the command's writes.
private struct BufferIdempotencyStore: IdempotencyStore {
    let tx: RecordingTransaction

    private func slot(_ id: String) -> String { "idem::\(id)" }

    func reserve(id: String, fingerprint: RequestFingerprint) async throws -> IdempotencyReservation {
        if let stored = await tx.read(slot(id)) {
            return .replay(StoredResponse(status: 200, body: Data(stored.utf8)))
        }
        return .proceed(IdempotencyTicket(id: id, fingerprint: fingerprint, overwriteExpired: false))
    }

    func complete(ticket: IdempotencyTicket, response: StoredResponse) async throws {
        await tx.stage(slot(ticket.id), "record")
    }
}

// MARK: - Command + work handler under test

private struct AtomicCommand: Command {
    struct Payload: Codable, Sendable { let value: String }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "atomic")
}

private struct AtomicResult: Codable, Sendable, Equatable { let ok: Bool }

/// Stages a "work" write into the transaction, then optionally fails — modelling
/// a command whose own persistence shares the transaction.
private struct WorkCommandHandler: IdempotentCommandHandler {
    typealias Params = AtomicCommand
    typealias Result = AtomicResult

    let unitOfWork: any UnitOfWork
    let idempotency: IdempotencyComponents
    let throwAfterWrite: Bool

    struct WorkError: Error {}

    func perform(_ command: AtomicCommand, in context: any UnitOfWorkContext) async throws -> AtomicResult {
        let tx = context.transaction as! RecordingTransaction
        await tx.stage("work::\(command.payload.value)", command.payload.value)
        if throwAfterWrite { throw WorkError() }
        return AtomicResult(ok: true)
    }
}

@Suite("Idempotency atomicity (same transaction)")
struct IdempotencyAtomicityTests {

    private let config = IdempotencyConfiguration.default

    private func recordSlot(forKey key: String) throws -> String {
        let id = config.scope.recordId(
            key: try IdempotencyKey(key),
            commandType: String(reflecting: AtomicCommand.self),
            principalId: nil
        )
        return "idem::\(id)"
    }

    private func makeSUT(uow: RecordingUnitOfWork, throwAfterWrite: Bool = false) -> WorkCommandHandler {
        WorkCommandHandler(
            unitOfWork: uow,
            idempotency: IdempotencyComponents(
                storeFactory: { ctx in BufferIdempotencyStore(tx: ctx.transaction as! RecordingTransaction) },
                configuration: config
            ),
            throwAfterWrite: throwAfterWrite
        )
    }

    // MARK: - Success: record + work commit together

    @Test("record and work commit in the same transaction")
    func recordAndWorkCommitTogether() async throws {
        let tx = RecordingTransaction()
        let uow = RecordingUnitOfWork(tx: tx)
        let sut = makeSUT(uow: uow)

        let result = try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("commit")) {
            try await sut.handle(AtomicCommand(payload: .init(value: "X")))
        }

        #expect(result == AtomicResult(ok: true))
        // Both the work write AND the idempotency record are now committed.
        #expect(await tx.committed["work::X"] == "X")
        #expect(await tx.committed[try recordSlot(forKey: "commit")] == "record")
    }

    // MARK: - Work failure: nothing persists (no marked-but-not-done)

    @Test("when the work fails, neither the work nor an idempotency record persists")
    func workFailureRollsBackTogether() async throws {
        let tx = RecordingTransaction()
        let uow = RecordingUnitOfWork(tx: tx)
        let sut = makeSUT(uow: uow, throwAfterWrite: true)

        await #expect(throws: WorkCommandHandler.WorkError.self) {
            try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("fail")) {
                try await sut.handle(AtomicCommand(payload: .init(value: "Y")))
            }
        }

        // Rolled back: the work write is gone, and crucially no record was left
        // behind — so the key is free for a genuine retry.
        #expect(await tx.committed.isEmpty)
        #expect(await tx.committed[try recordSlot(forKey: "fail")] == nil)
    }

    // MARK: - Commit failure: record + work roll back together

    @Test("when the commit fails after storing, record and work roll back together")
    func commitFailureRollsBackTogether() async throws {
        let tx = RecordingTransaction()
        let uow = RecordingUnitOfWork(tx: tx, failAtCommit: true)
        let sut = makeSUT(uow: uow)

        await #expect(throws: RecordingUnitOfWork.CommitFailure.self) {
            try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("commit-fail")) {
                try await sut.handle(AtomicCommand(payload: .init(value: "Z")))
            }
        }

        // The work write and the (staged) record were discarded together: no
        // "done-but-not-marked" and no "marked-but-not-done".
        #expect(await tx.committed.isEmpty)
    }
}
