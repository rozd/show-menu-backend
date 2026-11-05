//
//  IntegrationEvent.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 2/1/26.
//

import Foundation

// MARK: - Metadata

/// Common metadata for all integration events.
///
/// Extracted as a separate struct for:
/// - Clean separation of concerns
/// - Reusability across event types
/// - Easier testing and comparison
struct IntegrationEventMetadata: Codable, Sendable, Equatable {
    /// Identifier of the bounded context that produced this event.
    /// Example: "Users", "Orders", "Notifications"
    let origin: String

    /// Optional correlation ID for request tracing across bounded contexts.
    /// Set when an event is triggered by a specific user request.
    let correlationId: TraceID?

    /// Timestamp when the event occurred (UTC).
    let occurredAt: Date

    init(origin: String, correlationId: TraceID? = nil, occurredAt: Date = .now) {
        self.origin = origin
        self.correlationId = correlationId
        self.occurredAt = occurredAt
    }
}

// MARK: - Metadata Convenience

extension IntegrationEventMetadata {
    /// Create metadata with just origin (most common case).
    static func from(origin: String) -> Self {
        .init(origin: origin)
    }

    /// Create metadata with origin and correlation ID for request tracing.
    static func from(origin: String, correlationId: TraceID) -> Self {
        .init(origin: origin, correlationId: correlationId)
    }
}

// MARK: - Core Protocol

/// An event intended for cross-bounded-context communication.
///
/// Integration events differ from domain events:
/// - Domain events use rich domain types and are internal to a bounded context
/// - Integration events use primitive types and cross bounded context boundaries
///
/// Conforming types must be value types (structs) for immutability.
///
/// **Naming Conventions**:
/// - `kind` aligns with `DomainEvent.Kind` pattern in this codebase
/// - `origin` (in Metadata) matches distributed tracing terminology
protocol IntegrationEvent: Identifiable, Codable, Sendable where ID == UUID {
    /// Type discriminator for serialization/deserialization.
    /// Defaults to the type name. Override for custom names (e.g., "users.registered").
    static var kind: String { get }

    /// Unique identifier for this event instance.
    var id: UUID { get }

    /// Common event metadata (origin, correlationId, occurredAt).
    var metadata: IntegrationEventMetadata { get }
}

// MARK: - Default Implementation

extension IntegrationEvent {
    static var kind: String {
        String(describing: Self.self)
    }
}

// MARK: - Envelope

/// Transport wrapper for heterogeneous event handling.
///
/// The envelope contains:
/// - Event ID and kind (type discriminator)
/// - Event metadata (origin, correlationId, occurredAt)
/// - JSON-encoded payload for the concrete event
struct IntegrationEventEnvelope: Codable, Sendable {
    let id: UUID
    let kind: String
    let metadata: IntegrationEventMetadata
    let payload: Data

    init<E: IntegrationEvent>(wrapping event: E, payload: Data) {
        self.id = event.id
        self.kind = E.kind
        self.metadata = event.metadata
        self.payload = payload
    }

    /// Reconstruct an envelope from its stored parts. Used by the transactional
    /// outbox to rebuild a transport envelope from a persisted `OutboxMessage`
    /// before republishing it through an `IntegrationEventChannel`.
    init(id: UUID, kind: String, metadata: IntegrationEventMetadata, payload: Data) {
        self.id = id
        self.kind = kind
        self.metadata = metadata
        self.payload = payload
    }
}

// MARK: - Errors

enum IntegrationEventError: Error, Sendable, Equatable {
    case unknownEventKind(String)
    case encodingFailed(String)
    case decodingFailed(String)
}

// MARK: - Registry

/// Actor-based type registry for deserializing events by kind discriminator.
///
/// Register event types at application startup:
/// ```swift
/// await registry.register(UserCreatedIntegrationEvent.self)
/// ```
actor IntegrationEventRegistry {
    static let shared = IntegrationEventRegistry()

    private var decoders: [String: @Sendable (Data) throws -> any IntegrationEvent] = [:]

    func register<E: IntegrationEvent>(_ type: E.Type) {
        decoders[E.kind] = { data in
            try JSONDecoder().decode(E.self, from: data)
        }
    }

    func decode(kind: String, from data: Data) throws -> any IntegrationEvent {
        guard let decoder = decoders[kind] else {
            throw IntegrationEventError.unknownEventKind(kind)
        }
        return try decoder(data)
    }

    /// Check if a kind is registered.
    func isRegistered(kind: String) -> Bool {
        decoders[kind] != nil
    }

    /// Clear all registrations (for testing).
    func clear() {
        decoders.removeAll()
    }
}
