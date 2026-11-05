//
//  IntegrationEventCoder.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 2/1/26.
//

import Foundation

// MARK: - Coder Protocol

/// Serialization abstraction for integration events.
///
/// Responsible for:
/// - Encoding typed events to transport-safe envelopes
/// - Decoding envelopes back to typed events using the registry
protocol IntegrationEventCoder: Sendable {
    /// Encode a typed event into a transport envelope.
    ///
    /// - Parameter event: The integration event to encode
    /// - Returns: Envelope containing serialized event
    /// - Throws: `IntegrationEventError.encodingFailed` if serialization fails
    func encode<E: IntegrationEvent>(_ event: E) throws -> IntegrationEventEnvelope

    /// Decode a transport envelope back to a typed event.
    ///
    /// - Parameter envelope: The envelope to decode
    /// - Returns: The reconstructed typed event
    /// - Throws: `IntegrationEventError.unknownEventKind` or `.decodingFailed`
    func decode(_ envelope: IntegrationEventEnvelope) async throws -> any IntegrationEvent
}

// MARK: - JSON Implementation

/// JSON-based coder using standard Foundation JSONEncoder/Decoder.
///
/// Uses `IntegrationEventRegistry` to look up types during decoding.
struct JSONIntegrationEventCoder: IntegrationEventCoder {
    private let encoder: JSONEncoder
    private let registry: IntegrationEventRegistry

    init(
        encoder: JSONEncoder = JSONEncoder(),
        registry: IntegrationEventRegistry = .shared
    ) {
        self.encoder = encoder
        self.registry = registry
    }

    func encode<E: IntegrationEvent>(_ event: E) throws -> IntegrationEventEnvelope {
        do {
            let payload = try encoder.encode(event)
            return IntegrationEventEnvelope(wrapping: event, payload: payload)
        } catch {
            throw IntegrationEventError.encodingFailed(
                "Failed to encode \(E.kind): \(error.localizedDescription)"
            )
        }
    }

    func decode(_ envelope: IntegrationEventEnvelope) async throws -> any IntegrationEvent {
        do {
            return try await registry.decode(kind: envelope.kind, from: envelope.payload)
        } catch let error as IntegrationEventError {
            throw error
        } catch {
            throw IntegrationEventError.decodingFailed(
                "Failed to decode \(envelope.kind): \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Convenience Extensions

extension IntegrationEventEnvelope {
    /// Decode this envelope to its typed event.
    ///
    /// Convenience method using the default JSON coder.
    func decode() async throws -> any IntegrationEvent {
        try await JSONIntegrationEventCoder().decode(self)
    }

    /// Encode to JSON data for transport.
    func toJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decode from JSON data received from transport.
    static func fromJSON(_ data: Data) throws -> IntegrationEventEnvelope {
        try JSONDecoder().decode(IntegrationEventEnvelope.self, from: data)
    }
}
