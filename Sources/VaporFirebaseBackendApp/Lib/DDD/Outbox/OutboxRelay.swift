//
//  OutboxRelay.swift
//  VaporFirebaseBackendApp
//
//  Drains the outbox and publishes through the existing IntegrationEventChannel.
//

import Foundation
import Logging

// MARK: - Relay

/// Drains the outbox: publishes due messages through the real
/// ``IntegrationEventChannel``, marks them published, retries failures with
/// backoff, and prunes published rows past their retention window.
///
/// **Delivery is at-least-once.** A crash after publish but before
/// `markPublished` republishes the message on the next drain; downstream
/// consumers must dedup (see ``InboxedCommandHandler``, the consumer-side
/// Inbox). No attempt is made at exactly-once.
///
/// **Ordering is best-effort FIFO.** Messages are drained in (`createdAt`,
/// `sequence`) order and published *sequentially* to preserve it. Strict
/// per-aggregate ordering across transactions is not guaranteed — see the module
/// docs for how to add it (partition by aggregate + ordered fetch).
///
/// The relay publishes through `publish`, an injected adapter over the channel.
/// It is `throws` so a transport that *can* report failure surfaces it here and
/// the row stays `pending` for retry. The default adapter wraps the fire-and-
/// forget `IntegrationEventChannel.publish` (which logs rather than throws), so
/// with that channel end-to-end delivery is "durably recorded and handed to the
/// channel at least once" — the channel then owns its own transport durability.
struct OutboxRelay: Sendable {

    let store: any OutboxStore
    let publish: @Sendable (any IntegrationEvent) async throws -> Void
    let coder: any IntegrationEventCoder
    let backoff: RetryPolicy.Backoff
    let batchSize: Int
    let retention: TimeInterval
    let now: @Sendable () -> Date
    let logger: Logger

    struct Summary: Sendable, Equatable {
        var published = 0
        var failed = 0
        var deleted = 0
    }

    /// Run one drain pass: publish due messages, then prune old published rows.
    @discardableResult
    func drain() async -> Summary {
        var summary = Summary()

        let messages: [OutboxMessage]
        do {
            messages = try await store.pending(limit: batchSize, now: now())
        } catch {
            logger.error("Outbox relay failed to fetch pending messages", metadata: [
                "error": .string(String(describing: error))
            ])
            return summary
        }

        // Publish sequentially to preserve best-effort FIFO ordering.
        for message in messages {
            do {
                let event = try await coder.decode(message.envelope)
                try await publish(event)
                try await store.markPublished(id: message.id, at: now())
                summary.published += 1
            } catch {
                let attempts = message.attempts + 1
                let availableAt = now().addingTimeInterval(backoff.delay(forAttempt: attempts))
                logger.warning("Outbox relay failed to publish message", metadata: [
                    "messageId": .string(message.id.uuidString),
                    "kind": .string(message.kind),
                    "attempts": .string(String(attempts)),
                    "error": .string(String(describing: error))
                ])
                do {
                    try await store.recordFailure(
                        id: message.id,
                        attempts: attempts,
                        availableAt: availableAt,
                        error: String(describing: error)
                    )
                } catch {
                    logger.error("Outbox relay failed to record failure", metadata: [
                        "messageId": .string(message.id.uuidString),
                        "error": .string(String(describing: error))
                    ])
                }
                summary.failed += 1
            }
        }

        // TTL cleanup so the outbox does not grow unbounded.
        do {
            let cutoff = now().addingTimeInterval(-retention)
            summary.deleted = try await store.deletePublished(publishedBefore: cutoff, limit: batchSize)
        } catch {
            logger.error("Outbox relay failed to prune published messages", metadata: [
                "error": .string(String(describing: error))
            ])
        }

        if summary.published > 0 || summary.failed > 0 || summary.deleted > 0 {
            logger.info("Outbox relay drain complete", metadata: [
                "published": .string(String(summary.published)),
                "failed": .string(String(summary.failed)),
                "deleted": .string(String(summary.deleted))
            ])
        }
        return summary
    }
}
