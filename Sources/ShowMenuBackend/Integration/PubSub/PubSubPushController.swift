//
//  PubSubPushController.swift
//  ShowMenuBackend
//

import Vapor

/// Receives push messages from Pub/Sub and dispatches them as integration events.
///
/// Replaces the pull-based `PubSubIntegrationEventSubscriber` with Cloud Run's
/// native request-driven model — Pub/Sub POSTs to `POST /internal/events`,
/// the controller decodes and dispatches, then returns 200.
///
/// **Decode path** (reverse of `PubSubIntegrationEventChannel.publish`):
/// ```
/// PubSubPushEnvelope.message.data (base64) → JSON → IntegrationEventEnvelope → coder.decode() → typed event → dispatcher.dispatch()
/// ```
///
/// **Error handling**:
/// - Returns **200** for all outcomes to prevent Pub/Sub infinite retries.
///   Permanent failures (bad body, invalid base64, unknown event kind) are logged
///   and acknowledged. Handler errors are caught inside the dispatcher (fire-and-forget).
struct PubSubPushController: Sendable {
    let dispatcher: any IntegrationEventDispatcher
    let coder: any IntegrationEventCoder
    let logger: Logger

    /// Vapor entry point — decodes request body into `PubSubPushEnvelope`.
    @Sendable
    func handlePush(req: Request) async throws -> HTTPStatus {
        let envelope: PubSubPushEnvelope
        do {
            envelope = try req.content.decode(PubSubPushEnvelope.self)
        } catch {
            req.logger.error("Failed to decode Pub/Sub push envelope", metadata: [
                "error": .string(String(describing: error)),
            ])
            return .ok
        }

        return await handle(envelope)
    }

    /// Testable core — operates on `PubSubPushEnvelope` directly.
    func handle(_ envelope: PubSubPushEnvelope) async -> HTTPStatus {
        // Step 1: Base64 decode
        guard let jsonData = Data(base64Encoded: envelope.message.data) else {
            logger.error("Invalid base64 in Pub/Sub push message", metadata: [
                "messageId": .string(envelope.message.messageId),
                "subscription": .string(envelope.subscription),
                "dataPrefix": .string(String(envelope.message.data.prefix(50))),
            ])
            return .ok
        }

        // Step 2: Decode envelope JSON
        let eventEnvelope: IntegrationEventEnvelope
        do {
            eventEnvelope = try JSONDecoder().decode(IntegrationEventEnvelope.self, from: jsonData)
        } catch {
            logger.error("Failed to decode IntegrationEventEnvelope from Pub/Sub push", metadata: [
                "messageId": .string(envelope.message.messageId),
                "error": .string(String(describing: error)),
            ])
            return .ok
        }

        // Step 3: Decode typed event
        let event: any IntegrationEvent
        do {
            event = try await coder.decode(eventEnvelope)
        } catch {
            logger.error("Failed to decode integration event from envelope", metadata: [
                "messageId": .string(envelope.message.messageId),
                "kind": .string(eventEnvelope.kind),
                "error": .string(String(describing: error)),
            ])
            return .ok
        }

        logger.info("Dispatching integration event from Pub/Sub push", metadata: [
            "kind": .string(eventEnvelope.kind),
            "eventId": .string(event.id.uuidString),
            "origin": .string(event.metadata.origin),
            "correlationId": .stringConvertible(event.metadata.correlationId ?? "nil"),
            "messageId": .string(envelope.message.messageId),
        ])

        // Step 4: Dispatch — handlers are fire-and-forget via IntegrationEventDispatcher
        await dispatchTyped(event)

        return .ok
    }

    // MARK: - Existential Opening

    /// Dispatch using existential opening to preserve the concrete type for
    /// the generic `IntegrationEventDispatcher.dispatch<E>(_:)`.
    private func dispatchTyped<E: IntegrationEvent>(_ event: E) async {
        await dispatcher.dispatch(event)
    }
}

// MARK: - Route Collection

struct PubSubPushRouteV1: RouteCollection {
    let controller: PubSubPushController

    func boot(routes: any RoutesBuilder) throws {
        routes.post("events", use: controller.handlePush)
    }
}
