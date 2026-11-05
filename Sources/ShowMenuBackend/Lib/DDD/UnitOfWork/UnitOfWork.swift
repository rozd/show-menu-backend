//
//  UnitOfWork.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/19/25.
//

protocol UnitOfWork: Sendable {
    associatedtype Context: UnitOfWorkContext

    var dispatcher: any DomainEventDispatcher { get }

    func execute<Result: Sendable>(
        _ work: @escaping @Sendable (Context) async throws -> Result
    ) async throws -> Result
}

protocol UnitOfWorkContext: Sendable {
    associatedtype Transaction: Sendable

    var transaction: Transaction { get }

    var collector: any DomainEventCollector { get }

    /// The in-transaction integration-event recorder for this unit of work.
    ///
    /// Symmetric to `collector`: where the collector gathers domain events for
    /// post-commit dispatch, the outbox channel records integration events into
    /// durable storage **bound to this work's transaction**, so they commit
    /// atomically with the state change and a relay publishes them afterwards
    /// (see ``OutboxIntegrationEventChannel``). A use case that needs to emit an
    /// integration event does `try await context.outbox.record(event)`.
    var outbox: OutboxIntegrationEventChannel { get }
}
