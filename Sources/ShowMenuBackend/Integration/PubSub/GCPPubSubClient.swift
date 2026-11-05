//
//  GCPPubSubClient.swift
//  ShowMenuBackend
//

import Foundation
import Vapor

/// Google Cloud Pub/Sub REST API client.
///
/// Follows the same pattern as `GCPCloudTasksClient`:
/// - Uses Vapor `Client` for HTTP
/// - Bearer token from `AuthProvider` (nil for emulator — no auth needed)
/// - Configurable `baseURL` for emulator support
struct GCPPubSubClient: PubSubClient {
    static let defaultBaseURL = "https://pubsub.googleapis.com"

    let client: any Client
    let authProvider: (any GCPAuthProvider)?
    let config: Config
    let logger: Logger

    func publish(message: PubSubMessage, to topic: String) async throws {
        let url = "\(config.baseURL)/v1/projects/\(config.projectId)/topics/\(topic):publish"

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        if let authProvider {
            guard let token = try await authProvider.getAccessToken() else {
                throw PubSubError.authenticationFailed
            }
            headers.add(name: .authorization, value: "Bearer \(token)")
        }

        let request = PubSubPublishRequest(messages: [message])
        let bodyData = try JSONEncoder().encode(request)

        let uri = URI(string: url)
        let response = try await client.post(uri, headers: headers) { req in
            req.body = .init(data: bodyData)
        }

        guard (200...299).contains(response.status.code) else {
            let responseBody = response.body.map { String(buffer: $0) } ?? ""
            logger.error("Pub/Sub publish failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(responseBody),
                "topic": .string(topic),
            ])
            throw PubSubError.publishFailed(
                statusCode: Int(response.status.code),
                message: responseBody
            )
        }

        logger.info("Pub/Sub message published", metadata: ["topic": .string(topic)])
    }

    // MARK: - Infrastructure

    /// Ensure a topic exists (creates if missing).
    ///
    /// The GCP Pub/Sub emulator does **not** auto-create topics, so call this
    /// once at startup when using the emulator.
    func ensureTopicExists(_ topic: String) async throws {
        let url = "\(config.baseURL)/v1/projects/\(config.projectId)/topics/\(topic)"

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        if let authProvider {
            guard let token = try await authProvider.getAccessToken() else {
                throw PubSubError.authenticationFailed
            }
            headers.add(name: .authorization, value: "Bearer \(token)")
        }

        let uri = URI(string: url)
        let response = try await client.put(uri, headers: headers) { _ in }

        // 200 = created, 409 = already exists — both are fine
        guard (200...299).contains(response.status.code) || response.status.code == 409 else {
            let responseBody = response.body.map { String(buffer: $0) } ?? ""
            logger.error("Pub/Sub topic creation failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(responseBody),
                "topic": .string(topic),
            ])
            throw PubSubError.publishFailed(
                statusCode: Int(response.status.code),
                message: responseBody
            )
        }

        logger.info("Pub/Sub topic ensured", metadata: ["topic": .string(topic)])
    }

    /// Ensure a push subscription exists for the given topic.
    ///
    /// Creates a subscription with a push endpoint if it doesn't already exist.
    /// On the emulator this is required because subscriptions are not auto-created.
    /// On production, push subscriptions are typically created via Terraform/gcloud,
    /// so this call returns 409 (already exists) which is handled gracefully.
    func ensurePushSubscriptionExists(
        _ subscription: String,
        for topic: String,
        pushEndpoint: String
    ) async throws {
        let url = "\(config.baseURL)/v1/projects/\(config.projectId)/subscriptions/\(subscription)"

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        if let authProvider {
            guard let token = try await authProvider.getAccessToken() else {
                throw PubSubError.authenticationFailed
            }
            headers.add(name: .authorization, value: "Bearer \(token)")
        }

        struct PushSubscriptionConfig: Codable {
            let topic: String
            let pushConfig: PushConfig

            struct PushConfig: Codable {
                let pushEndpoint: String
            }
        }

        let body = PushSubscriptionConfig(
            topic: "projects/\(config.projectId)/topics/\(topic)",
            pushConfig: .init(pushEndpoint: pushEndpoint)
        )
        let bodyData = try JSONEncoder().encode(body)

        let uri = URI(string: url)
        let response = try await client.put(uri, headers: headers) { req in
            req.body = .init(data: bodyData)
        }

        // 200 = created, 409 = already exists — both are fine
        guard (200...299).contains(response.status.code) || response.status.code == 409 else {
            let responseBody = response.body.map { String(buffer: $0) } ?? ""
            logger.error("Pub/Sub push subscription creation failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(responseBody),
                "subscription": .string(subscription),
                "topic": .string(topic),
            ])
            throw PubSubError.subscriptionCreationFailed(
                statusCode: Int(response.status.code),
                message: responseBody
            )
        }

        logger.info("Pub/Sub push subscription ensured", metadata: [
            "subscription": .string(subscription),
            "topic": .string(topic),
            "pushEndpoint": .string(pushEndpoint),
        ])
    }
}

// MARK: - Pub/Sub Config

extension GCPPubSubClient {

    struct Config: Sendable {
        let projectId: String
        let baseURL: String
    }

}

extension GCPPubSubClient.Config {

    static func fromEnvironment(
        with config: GoogleCloudPlatform.Configuration,
    ) -> Self {
        .init(
            projectId: config.projectID,
            baseURL: Environment.gcpPubSubURL,
        )
    }
}
