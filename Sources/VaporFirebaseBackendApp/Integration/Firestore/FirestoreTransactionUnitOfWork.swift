import Logging
import GRPCCore
@preconcurrency import FirestoreAPI

struct FirestoreTransactionUnitOfWork<Transport: ClientTransport>: UnitOfWork {

    let firestore: Firestore<Transport>
    var dispatcher: any DomainEventDispatcher
    let outbox: Outbox
    let logger: Logger

    func execute<Result: Sendable>(
        _ work: @escaping @Sendable (FirestoreTransactionUnitOfWorkContext) async throws -> Result
    ) async throws -> Result {
        logger.debug("UnitOfWork executing")
        let collector = InMemoryDomainEventCollector()
        let outbox = self.outbox
        let logger = self.logger

        let result: Result
        do {
            result = try await firestore.runInTransaction { transaction in
                // The outbox store is bound to THIS transaction, so recorded
                // integration events are buffered as part of it and commit
                // atomically with the aggregate's state change (or roll back).
                let store = FirestoreOutboxStore(
                    transaction: transaction,
                    collection: outbox.collection,
                    logger: logger
                )
                return try await work(.init(
                    transaction: transaction,
                    collector: collector,
                    outbox: outbox.channel(store: store),
                ))
            }
        } catch let conflict as ConcurrencyError {
            // Optimistic-concurrency conflict raised by a check-and-set write.
            // Surface it unchanged so the CommandHandler/edge can map it to
            // 409/412 — never collapse it into a generic Firestore error.
            throw conflict
        } catch FirestoreAPI.FirestoreError.transactionFailed(let underlying) {
            // The transaction runner retries the closure and finally wraps the
            // last error; unwrap a conflict that survived the retries.
            if let conflict = underlying as? ConcurrencyError {
                throw conflict
            }
            if underlying is FirestoreAPI.FirestoreError || underlying is RPCError {
                throw FirestoreError.from(grpcError: underlying)
            }
            throw underlying
        }

        let events = await collector.drain()
        logger.info("UnitOfWork committed", metadata: [
            "domainEventCount": .string(String(events.count))
        ])
        await dispatcher.dispatch(events: events)
        return result
    }
}

struct FirestoreTransactionUnitOfWorkContext: UnitOfWorkContext {
    let transaction: FirestoreTransaction
    let collector: any DomainEventCollector
    let outbox: OutboxIntegrationEventChannel
}
