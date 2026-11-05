//
//  IntegrationEventHandler.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 2/1/26.
//

import Foundation
import Logging

// MARK: - Handler Protocol

/// Handler for processing received integration events.
///
/// Integration Event Handlers:
/// - Live in `Application/Event/Handler/Integration/`
/// - Receive events from IntegrationEventDispatcher
/// - Decide whether to process or ignore the event
/// - **Delegate to Commands** for actual work
///
/// Handlers should be idempotent as events may be delivered multiple times.
///
/// Example:
/// ```swift
/// // Application/Event/Handler/Integration/SendWelcomeEmailOnUserRegisteredHandler.swift
/// struct SendWelcomeEmailOnUserRegisteredHandler: IntegrationEventHandler {
///     let commandHandler: SendWelcomeEmailCommandHandler
///     let logger: Logger
///
///     func handle(_ event: UserCreatedIntegrationEvent) async throws {
///         // Decide: process or ignore?
///         guard shouldProcess(event) else { return }
///
///         // Delegate to command
///         let command = SendWelcomeEmailCommand(
///             payload: SendWelcomeEmailDTO(email: event.email),
///             metadata: CommandMetadata(correlationId: event.metadata.correlationId)
///         )
///         try await commandHandler.handle(command)
///     }
/// }
/// ```
///
/// **Naming Pattern**: `{Action}On{IntegrationEvent}Handler`
protocol IntegrationEventHandler: Sendable {
    /// The specific event type this handler processes.
    associatedtype Event: IntegrationEvent

    /// Process the received event.
    ///
    /// Handlers should:
    /// 1. Decide whether to process or ignore the event
    /// 2. If processing, delegate to a Command
    /// 3. Pass correlation ID to maintain tracing context
    ///
    /// Errors thrown here are caught by the dispatcher, logged, and the event is dropped.
    ///
    /// - Parameter event: The event to process
    func handle(_ event: Event) async throws
}

// MARK: - Dispatcher Protocol

/// Routes received integration events to registered handlers.
///
/// Similar to `DomainEventDispatcher` pattern in this codebase.
protocol IntegrationEventDispatcher: Sendable {
    /// Dispatch an event to all registered handlers for its kind.
    ///
    /// Handlers are invoked concurrently. Errors in one handler do not
    /// affect other handlers (fire-and-forget).
    func dispatch<E: IntegrationEvent>(_ event: E) async

    /// Register a handler for a specific event kind.
    ///
    /// Multiple handlers can be registered for the same event kind.
    func register<H: IntegrationEventHandler>(handler: H) async
}

// MARK: - In-Memory Dispatcher

/// In-memory dispatcher for testing and local development.
///
/// Follows the same pattern as `InMemoryDomainEventDispatcher`.
actor InMemoryIntegrationEventDispatcher: IntegrationEventDispatcher {
    private struct HandlerBox: Sendable {
        let handle: @Sendable (any IntegrationEvent) async -> Void
    }

    private var handlers: [String: [HandlerBox]] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func dispatch<E: IntegrationEvent>(_ event: E) async {
        let key = E.kind
        guard let boxes = handlers[key] else {
            logger.info("No handlers registered for event kind", metadata: [
                "kind": .string(key)
            ])
            return
        }

        // Log dispatch with correlation context
        logger.info("Dispatching integration event", metadata: [
            "kind": .string(key),
            "eventId": .string(event.id.uuidString),
            "origin": .string(event.metadata.origin),
            "correlationId": .stringConvertible(event.metadata.correlationId ?? "nil"),
            "handlerCount": .string(String(boxes.count))
        ])

        // Dispatch to all handlers concurrently
        await withTaskGroup(of: Void.self) { group in
            for box in boxes {
                group.addTask {
                    await box.handle(event)
                }
            }
        }
    }

    func register<H: IntegrationEventHandler>(handler: H) async {
        let key = H.Event.kind
        let box = HandlerBox { [logger] event in
            guard let typed = event as? H.Event else {
                return
            }
            do {
                // Bind the event id so an `InboxedCommandHandler` downstream can
                // de-duplicate redeliveries of this event per consumer.
                try await RequestContext.$integrationEventId.withValue(typed.id) {
                    try await handler.handle(typed)
                }
            } catch {
                // Fire-and-forget: log error and continue
                logger.error("Handler failed for event", metadata: [
                    "kind": .string(key),
                    "error": .string(String(describing: error))
                ])
            }
        }
        handlers[key, default: []].append(box)

        logger.info("Registered handler for event kind", metadata: [
            "kind": .string(key)
        ])
    }

    /// Clear all handlers (for testing).
    func clear() {
        handlers.removeAll()
    }
}
