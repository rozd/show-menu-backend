//
//  OutboxIntegrationEventChannel.swift
//  ShowMenuBackend
//
//  The in-transaction write side of the outbox.
//

import Foundation

/// The **in-transaction write side** of the outbox.
///
/// Where a normal ``IntegrationEventChannel`` *transmits* an event (fire-and-
/// forget, after commit), this channel *records* it into the ``OutboxStore``
/// bound to the current Unit of Work transaction — so the event commits
/// atomically with the state change and a relay (``OutboxRelay``) publishes it
/// afterwards through the real channel.
///
/// It is deliberately **not** an `IntegrationEventChannel`. That protocol's
/// `publish` is non-throwing fire-and-forget, but an outbox write that fails MUST
/// abort the transaction (otherwise committed state would have no event) — so
/// `record` throws. Recording surface, not a transport.
///
/// One instance is created per Unit of Work execution, bound to that execution's
/// transaction-bound store, and exposed on ``UnitOfWorkContext`` alongside the
/// domain-event `collector`.
actor OutboxIntegrationEventChannel {

    private let store: any OutboxStore
    private let coder: any IntegrationEventCoder
    private let now: @Sendable () -> Date

    /// Per-transaction monotonic counter giving recorded events a stable relative
    /// order even when they share a `createdAt` tick.
    private var sequence = 0

    init(
        store: any OutboxStore,
        coder: any IntegrationEventCoder = JSONIntegrationEventCoder(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.coder = coder
        self.now = now
    }

    /// Record an integration event into the outbox within the active transaction.
    ///
    /// Throws if encoding or the transactional append fails — propagate it so the
    /// surrounding Unit of Work transaction rolls back.
    func record<E: IntegrationEvent>(_ event: E) async throws {
        let message = try OutboxMessage.pending(
            from: event,
            sequence: sequence,
            at: now(),
            coder: coder
        )
        try await store.append(message)
        sequence += 1
    }
}
