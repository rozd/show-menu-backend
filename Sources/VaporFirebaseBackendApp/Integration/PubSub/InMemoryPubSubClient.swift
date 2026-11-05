//
//  InMemoryPubSubClient.swift
//  VaporFirebaseBackendApp
//

import Foundation

/// Test double capturing published Pub/Sub messages.
///
/// Same pattern as `InMemoryCloudTasksClient` — actor that records calls
/// for assertion in unit tests.
actor InMemoryPubSubClient: PubSubClient {

    // MARK: - Published Messages

    struct PublishedMessage: Sendable {
        let message: PubSubMessage
        let topic: String
    }

    private(set) var publishedMessages: [PublishedMessage] = []

    // MARK: - Failure Simulation

    private var shouldFail: Bool = false

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    // MARK: - Publishing

    func publish(message: PubSubMessage, to topic: String) async throws {
        if shouldFail {
            throw PubSubError.publishFailed(statusCode: 500, message: "Simulated failure")
        }
        publishedMessages.append(PublishedMessage(message: message, topic: topic))
    }

    // MARK: - Infrastructure

    func ensureTopicExists(_ topic: String) async throws {
    }

    func ensurePushSubscriptionExists(_ subscription: String, for topic: String, pushEndpoint: String) async throws {
    }

    // MARK: - Test Helpers

    func reset() {
        publishedMessages.removeAll()
    }
}
