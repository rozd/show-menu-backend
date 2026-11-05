//
//  IntegrationEventChannel.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 2/1/26.
//

import Foundation
import Logging

// MARK: - Channel Protocol

/// Abstraction for publishing integration events to a transport layer.
///
/// Implementations may use:
/// - In-memory dispatch (testing, local development)
/// - Vapor Queues (Redis-backed, development/staging)
/// - Cloud Pub/Sub (production)
/// - HTTP webhooks (external systems)
///
/// The channel handles serialization internally using `IntegrationEventCoder`.
/// Errors are logged, not propagated (fire-and-forget strategy).
protocol IntegrationEventChannel: Sendable {
    /// Publish an event to the channel.
    ///
    /// The event is serialized to an envelope and transmitted.
    /// Errors are logged internally; this method does not throw.
    ///
    /// - Parameter event: The integration event to publish
    func publish<E: IntegrationEvent>(_ event: E) async
}

// MARK: - In-Memory Implementation

/// In-memory channel for testing and local development.
///
/// Dispatches events directly to registered handlers without serialization.
actor InMemoryIntegrationEventChannel: IntegrationEventChannel {
    private let dispatcher: any IntegrationEventDispatcher
    private let logger: Logger

    init(dispatcher: any IntegrationEventDispatcher, logger: Logger) {
        self.dispatcher = dispatcher
        self.logger = logger
    }

    func publish<E: IntegrationEvent>(_ event: E) async {
        logger.info("Publishing integration event", metadata: [
            "kind": .string(E.kind),
            "eventId": .string(event.id.uuidString),
            "origin": .string(event.metadata.origin),
            "correlationId": .stringConvertible(event.metadata.correlationId ?? "nil")
        ])
        await dispatcher.dispatch(event)
    }
}
