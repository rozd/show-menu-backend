import Foundation
import Testing
@testable import ShowMenuBackend

// MARK: - A transactional in-memory "transaction"
//
// Simulates one Firestore transaction: writes are *staged* (pending) and only
// become visible (committed) when the UnitOfWork commits; any failure discards
// the pending set. Both the command's work and the inbox store write into the
// *same* buffer, so we can assert they commit / roll back together.

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
    /// Unused here — this suite is about the inbox marker and the command's
    /// writes committing together, not about outbox recording.
    let outbox = OutboxIntegrationEventChannel(store: InMemoryOutboxStore())
}

private final class RecordingUnitOfWork: UnitOfWork, @unchecked Sendable {
    typealias Context = RecordingContext

    let dispatcher: any DomainEventDispatcher = SpyDomainEventDispatcher()
    let tx: RecordingTransaction
    /// When true, the transaction fails at commit *after* the work has run and the
    /// marker has been staged — exercising "both roll back together".
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

/// An ``InboxStore`` that reads/writes the shared `RecordingTransaction`, so its
/// marker is part of the same atomic unit as the command's writes.
private struct BufferInboxStore: InboxStore {
    let tx: RecordingTransaction

    static func slot(_ id: String) -> String { "inbox::\(id)" }

    func reserve(id: String) async throws -> InboxReservation {
        if await tx.read(Self.slot(id)) != nil { return .alreadyProcessed }
        return .proceed(InboxTicket(id: id, overwriteExpired: false))
    }

    func complete(ticket: InboxTicket) async throws {
        await tx.stage(Self.slot(ticket.id), "marker")
    }
}

// MARK: - Command + work handler under test

private struct AtomicCommand: Command {
    struct Payload: Codable, Sendable { let value: String }
    let payload: Payload
    let metadata: CommandMetadata = CommandMetadata(correlationId: "atomic")
}

/// Stages a "work" write into the transaction, then optionally fails — modelling
/// a command whose own persistence shares the transaction.
private struct WorkCommandHandler: InboxedCommandHandler {
    typealias Params = AtomicCommand
    typealias Result = Void

    let unitOfWork: any UnitOfWork
    let inbox: InboxComponents
    let throwAfterWrite: Bool

    struct WorkError: Error {}

    func perform(_ command: AtomicCommand, in context: any UnitOfWorkContext) async throws -> Void {
        let tx = context.transaction as! RecordingTransaction
        await tx.stage("work::\(command.payload.value)", command.payload.value)
        if throwAfterWrite { throw WorkError() }
    }
}

@Suite("Inbox atomicity (same transaction)")
struct InboxAtomicityTests {

    private func markerSlot(forEventId eventId: UUID) -> String {
        BufferInboxStore.slot(
            InboxRecordId.derive(consumer: String(reflecting: AtomicCommand.self), eventId: eventId)
        )
    }

    private func makeSUT(uow: RecordingUnitOfWork, throwAfterWrite: Bool = false) -> WorkCommandHandler {
        WorkCommandHandler(
            unitOfWork: uow,
            inbox: InboxComponents(
                storeFactory: { ctx in BufferInboxStore(tx: ctx.transaction as! RecordingTransaction) }
            ),
            throwAfterWrite: throwAfterWrite
        )
    }

    @Test("marker and work commit in the same transaction")
    func markerAndWorkCommitTogether() async throws {
        let tx = RecordingTransaction()
        let sut = makeSUT(uow: RecordingUnitOfWork(tx: tx))
        let eventId = UUID()

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(AtomicCommand(payload: .init(value: "X")))
        }

        #expect(await tx.committed["work::X"] == "X")
        #expect(await tx.committed[markerSlot(forEventId: eventId)] == "marker")
    }

    @Test("when the work fails, neither the work nor a marker persists")
    func workFailureRollsBackTogether() async throws {
        let tx = RecordingTransaction()
        let sut = makeSUT(uow: RecordingUnitOfWork(tx: tx), throwAfterWrite: true)
        let eventId = UUID()

        await #expect(throws: WorkCommandHandler.WorkError.self) {
            try await RequestContext.$integrationEventId.withValue(eventId) {
                try await sut.handle(AtomicCommand(payload: .init(value: "Y")))
            }
        }

        // No marker left behind, so the event is free for a genuine redelivery.
        #expect(await tx.committed.isEmpty)
    }

    @Test("when the commit fails after storing, marker and work roll back together")
    func commitFailureRollsBackTogether() async throws {
        let tx = RecordingTransaction()
        let sut = makeSUT(uow: RecordingUnitOfWork(tx: tx, failAtCommit: true))
        let eventId = UUID()

        await #expect(throws: RecordingUnitOfWork.CommitFailure.self) {
            try await RequestContext.$integrationEventId.withValue(eventId) {
                try await sut.handle(AtomicCommand(payload: .init(value: "Z")))
            }
        }

        #expect(await tx.committed.isEmpty)
    }

    @Test("a redelivery after a committed run is skipped without re-running the work")
    func redeliveryAfterCommitSkips() async throws {
        let tx = RecordingTransaction()
        let sut = makeSUT(uow: RecordingUnitOfWork(tx: tx))
        let eventId = UUID()

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await sut.handle(AtomicCommand(payload: .init(value: "first")))
            try await sut.handle(AtomicCommand(payload: .init(value: "second")))
        }

        #expect(await tx.committed["work::first"] == "first")
        #expect(await tx.committed["work::second"] == nil)
    }
}
