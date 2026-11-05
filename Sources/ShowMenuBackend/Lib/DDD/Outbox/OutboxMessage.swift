//
//  OutboxMessage.swift
//  ShowMenuBackend
//
//  The durable record of an integration event awaiting publication.
//

import Foundation

/// A transactionally-recorded integration event awaiting publication.
///
/// An `OutboxMessage` is written *inside the same transaction* as the state
/// change that produced it (see ``OutboxIntegrationEventChannel``), which is the
/// whole point of the pattern: the row and the state commit atomically, so a
/// crash can never leave committed state with no message (nor a message with
/// rolled-back state).
///
/// It stores the event in its transport-ready ``IntegrationEventEnvelope`` form
/// (kind + metadata + JSON payload) so the relay can republish it through the
/// existing ``IntegrationEventChannel`` without any domain knowledge.
struct OutboxMessage: Sendable, Equatable, Identifiable {

    enum Status: String, Codable, Sendable, Equatable {
        /// Recorded, not yet successfully published to the channel.
        case pending
        /// Published at least once; retained until TTL cleanup removes it.
        case published
    }

    /// Stable identity, equal to the wrapped integration event's id. It doubles
    /// as the store's document id, so re-recording the same event collides rather
    /// than creating a duplicate row.
    let id: UUID

    /// Event type discriminator (`IntegrationEvent.kind`).
    let kind: String

    /// JSON-encoded event payload (`IntegrationEventEnvelope.payload`).
    let payload: Data

    /// Event metadata (origin, correlationId, occurredAt).
    let metadata: IntegrationEventMetadata

    /// Order assigned at append time *within one transaction* (0, 1, 2, …).
    /// Combined with `createdAt`, it gives the relay a best-effort FIFO order
    /// (a stable tiebreaker for events recorded under the same clock tick).
    let sequence: Int

    var status: Status

    /// When the row was recorded (the producing transaction's clock).
    let createdAt: Date

    /// When the relay last published it (nil while pending).
    var publishedAt: Date?

    /// Number of publish attempts so far (drives retry backoff).
    var attempts: Int

    /// Earliest time the relay may (re)attempt publication. Advanced on failure.
    var availableAt: Date

    /// Last publish error, for diagnostics (nil while healthy).
    var lastError: String?
}

extension OutboxMessage {

    /// Build a fresh `pending` message from an integration event, encoding it via
    /// `coder`. `now` is the producing transaction's clock; `sequence` is the
    /// event's position among those recorded in the same transaction.
    static func pending<E: IntegrationEvent>(
        from event: E,
        sequence: Int,
        at now: Date,
        coder: any IntegrationEventCoder
    ) throws -> OutboxMessage {
        let envelope = try coder.encode(event)
        return OutboxMessage(
            id: envelope.id,
            kind: envelope.kind,
            payload: envelope.payload,
            metadata: envelope.metadata,
            sequence: sequence,
            status: .pending,
            createdAt: now,
            publishedAt: nil,
            attempts: 0,
            availableAt: now,
            lastError: nil
        )
    }

    /// Reconstruct the transport envelope for republication by the relay.
    var envelope: IntegrationEventEnvelope {
        IntegrationEventEnvelope(id: id, kind: kind, metadata: metadata, payload: payload)
    }
}
