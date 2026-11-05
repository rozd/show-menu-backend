//
//  Outbox.swift
//  ShowMenuBackend
//
//  Facade + configuration tying the outbox pieces together.
//

import Foundation
import Logging

/// Facade and configuration for the **Transactional Outbox**.
///
/// The pattern in one breath: instead of publishing an integration event
/// directly after a command commits (a dual-write that loses the event on a
/// crash between commit and publish), the command *records* the event into a
/// durable outbox **within its transaction** (``OutboxIntegrationEventChannel`` →
/// ``OutboxStore``). A background ``OutboxRelay`` then drains the outbox and
/// publishes each message through the existing ``IntegrationEventChannel``,
/// marking it sent. Once the transaction commits, the event *will* eventually
/// publish, across process crashes — at-least-once.
///
/// This facade holds the tunables and builds the two collaborators:
/// - ``channel(store:now:)`` — the in-transaction write side, bound to a
///   transaction-scoped store, handed to use cases via ``UnitOfWorkContext``.
/// - ``relay(store:channel:logger:now:)`` — the drain side, over a *direct*
///   (non-transactional) store and the real publication channel.
struct Outbox: Sendable {

    /// Logical store / Firestore collection name for outbox rows.
    var collection: String
    /// Maximum messages drained (and pruned) per relay run.
    var batchSize: Int
    /// How long published rows are retained before TTL cleanup removes them.
    var retention: TimeInterval
    /// Backoff applied to failed publications.
    var backoff: RetryPolicy.Backoff
    /// Serialization used on both the write side and the relay side.
    var coder: any IntegrationEventCoder

    init(
        collection: String = "outbox",
        batchSize: Int = 100,
        retention: TimeInterval = 7 * 24 * 60 * 60,
        backoff: RetryPolicy.Backoff = .exponential(initial: 5, multiplier: 2, cap: 300),
        coder: any IntegrationEventCoder = JSONIntegrationEventCoder()
    ) {
        self.collection = collection
        self.batchSize = batchSize
        self.retention = retention
        self.backoff = backoff
        self.coder = coder
    }

    /// Build the in-transaction recording channel over a transaction-bound store.
    func channel(
        store: any OutboxStore,
        now: @escaping @Sendable () -> Date = { .now }
    ) -> OutboxIntegrationEventChannel {
        OutboxIntegrationEventChannel(store: store, coder: coder, now: now)
    }

    /// Build the relay over a (direct) store and the real publication channel.
    ///
    /// The relay publishes through an adapter that forwards to
    /// `channel.publish`. Because that method is fire-and-forget, the adapter
    /// does not throw — see ``OutboxRelay`` for the delivery-guarantee caveat.
    func relay(
        store: any OutboxStore,
        channel: any IntegrationEventChannel,
        logger: Logger,
        now: @escaping @Sendable () -> Date = { .now }
    ) -> OutboxRelay {
        OutboxRelay(
            store: store,
            publish: { event in await Self.forward(event, to: channel) },
            coder: coder,
            backoff: backoff,
            batchSize: batchSize,
            retention: retention,
            now: now,
            logger: logger
        )
    }

    /// Open the `any IntegrationEvent` existential to call the generic
    /// `channel.publish`, mirroring `IntegrationEventJob.dispatchTyped`.
    private static func forward(_ event: any IntegrationEvent, to channel: any IntegrationEventChannel) async {
        await channel.publish(event)
    }
}
