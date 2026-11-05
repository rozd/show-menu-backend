//
//  VaporQueueIntegrationEventChannel.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 2/1/26.
//

import Foundation
import Vapor
import Queues

// MARK: - Vapor Queue Integration Event Channel

/// Vapor Queues-backed channel for publishing integration events.
///
/// Uses Vapor's job queue system to transmit events asynchronously.
/// Events are serialized to `IntegrationEventEnvelope` and enqueued as jobs.
actor VaporQueueIntegrationEventChannel: IntegrationEventChannel {
    private let queue: any Queue
    private let coder: any IntegrationEventCoder
    private let logger: Logger

    init(
        queue: any Queue,
        coder: any IntegrationEventCoder = JSONIntegrationEventCoder(),
        logger: Logger
    ) {
        self.queue = queue
        self.coder = coder
        self.logger = logger
    }

    func publish<E: IntegrationEvent>(_ event: E) async {
        do {
            let envelope = try coder.encode(event)

            logger.info("Enqueuing integration event job", metadata: [
                "kind": .string(E.kind),
                "eventId": .string(event.id.uuidString),
                "origin": .string(event.metadata.origin),
                "correlationId": .stringConvertible(event.metadata.correlationId ?? "nil")
            ])

            try await queue.dispatch(IntegrationEventJob.self, envelope)
        } catch {
            // Fire-and-forget: log error and continue
            logger.error("Failed to enqueue integration event", metadata: [
                "kind": .string(E.kind),
                "error": .string(error.localizedDescription)
            ])
        }
    }
}

// MARK: - Integration Event Job

/// Vapor Queues job for processing integration events.
///
/// Deserializes the envelope and dispatches to registered handlers.
struct IntegrationEventJob: AsyncJob {
    typealias Payload = IntegrationEventEnvelope

    let dispatcher: any IntegrationEventDispatcher
    let coder: any IntegrationEventCoder
    let logger: Logger

    init(
        dispatcher: any IntegrationEventDispatcher,
        coder: any IntegrationEventCoder = JSONIntegrationEventCoder(),
        logger: Logger
    ) {
        self.dispatcher = dispatcher
        self.coder = coder
        self.logger = logger
    }

    func dequeue(_ context: QueueContext, _ payload: IntegrationEventEnvelope) async throws {
        logger.info("Processing integration event job", metadata: [
            "kind": .string(payload.kind),
            "eventId": .string(payload.id.uuidString),
            "origin": .string(payload.metadata.origin),
            "correlationId": .stringConvertible(payload.metadata.correlationId ?? "nil")
        ])

        do {
            let event = try await coder.decode(payload)
            await dispatchEvent(event)
        } catch {
            // Log and rethrow to let Vapor Queues handle retries
            logger.error("Failed to decode integration event", metadata: [
                "kind": .string(payload.kind),
                "error": .string(error.localizedDescription)
            ])
            throw error
        }
    }

    private func dispatchEvent(_ event: any IntegrationEvent) async {
        // Use dynamic dispatch based on event type
        await dispatchTyped(event)
    }

    private func dispatchTyped<E: IntegrationEvent>(_ event: E) async {
        await dispatcher.dispatch(event)
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: IntegrationEventEnvelope) async throws {
        logger.error("Integration event job failed", metadata: [
            "kind": .string(payload.kind),
            "eventId": .string(payload.id.uuidString),
            "error": .string(error.localizedDescription)
        ])
    }
}
