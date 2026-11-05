//
//  PubSubIntegrationEventChannel.swift
//  ShowMenuBackend
//

import Foundation
import Logging

/// Pub/Sub-backed channel for publishing integration events.
///
/// Encodes events as `IntegrationEventEnvelope` → JSON → base64 → `PubSubMessage.data`.
/// Message attributes carry routing metadata (`eventKind`, `eventId`, `origin`).
/// Errors are logged, not propagated (fire-and-forget strategy).
actor PubSubIntegrationEventChannel: IntegrationEventChannel {
    private let pubSubClient: any PubSubClient
    private let topic: String
    private let coder: any IntegrationEventCoder
    private let logger: Logger

    init(
        pubSubClient: any PubSubClient,
        topic: String,
        coder: any IntegrationEventCoder = JSONIntegrationEventCoder(),
        logger: Logger
    ) {
        self.pubSubClient = pubSubClient
        self.topic = topic
        self.coder = coder
        self.logger = logger
    }

    func publish<E: IntegrationEvent>(_ event: E) async {
        do {
            let envelope = try coder.encode(event)
            let envelopeJSON = try envelope.toJSON()
            let base64Data = envelopeJSON.base64EncodedString()

            let message = PubSubMessage(
                data: base64Data,
                attributes: [
                    "eventKind": E.kind,
                    "eventId": event.id.uuidString,
                    "origin": event.metadata.origin,
                ]
            )

            logger.info("Publishing integration event to Pub/Sub", metadata: [
                "kind": .string(E.kind),
                "eventId": .string(event.id.uuidString),
                "origin": .string(event.metadata.origin),
                "topic": .string(topic),
                "correlationId": .string(event.metadata.correlationId?.description ?? "nil"),
            ])

            try await pubSubClient.publish(message: message, to: topic)
        } catch {
            // Fire-and-forget: log error and continue
            logger.error("Failed to publish integration event to Pub/Sub", metadata: [
                "kind": .string(E.kind),
                "eventId": .string(event.id.uuidString),
                "error": .string(error.localizedDescription),
            ])
        }
    }
}
