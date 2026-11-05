//
//  PubSubClient.swift
//  VaporFirebaseBackendApp
//

import Foundation
import Vapor

// MARK: - Client Protocol

/// Abstraction for publishing to Google Cloud Pub/Sub.
///
/// Implementations:
/// - `GCPPubSubClient` — REST API client for production/standalone/emulator
/// - `InMemoryPubSubClient` — Test double capturing published messages
protocol PubSubClient: Sendable {
    func publish(message: PubSubMessage, to topic: String) async throws
    func ensureTopicExists(_ topic: String) async throws
    func ensurePushSubscriptionExists(_ subscription: String, for topic: String, pushEndpoint: String) async throws
}

// MARK: - Message

struct PubSubMessage: Sendable, Codable {
    /// Base64-encoded message data
    let data: String

    /// Optional key-value attributes for message filtering/routing
    let attributes: [String: String]?
}

// MARK: - Publish Request

struct PubSubPublishRequest: Sendable, Codable {
    let messages: [PubSubMessage]
}

// MARK: - Push Envelope

/// Envelope sent by Pub/Sub push subscriptions to the HTTP endpoint.
///
/// Pub/Sub wraps each message in this structure before POSTing to the
/// push endpoint. The controller decodes this, extracts the base64 data,
/// and dispatches the integration event.
struct PubSubPushEnvelope: Codable, Sendable, Content {
    let message: Message
    let subscription: String

    struct Message: Codable, Sendable {
        let data: String
        let attributes: [String: String]?
        let messageId: String
        let publishTime: String?
    }
}

// MARK: - Errors

enum PubSubError: Error {
    case authenticationFailed
    case publishFailed(statusCode: Int, message: String)
    case subscriptionCreationFailed(statusCode: Int, message: String)
}
