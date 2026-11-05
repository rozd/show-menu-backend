import Vapor

/// Controller for handling Eventarc CloudEvents webhooks
struct EventarcWebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // POST / - Main webhook endpoint for Eventarc events
        routes.post(use: handleWebhook)
    }

    /// Handles incoming Eventarc webhook requests
    /// - Parameter req: The incoming request
    /// - Returns: HTTP 200 OK on success
    @Sendable
    func handleWebhook(req: Request) async throws -> HTTPStatus {
        // Check if this is a CloudEvents request
        guard CloudEventsParser.isCloudEventsRequest(req) else {
            // Not a CloudEvents request - this might be a health check or other traffic
            req.logger.debug("Non-CloudEvents request to webhook endpoint")
            return .ok
        }

        // Parse and validate the CloudEvents request
        let (headers, authData) = try await CloudEventsParser.parse(req)

        // Route to appropriate handler based on event type
        switch headers.type {
        case CloudEventsHeaders.firebaseAuthUserCreated:
            try await handleUserCreated(req: req, headers: headers, authData: authData)
        case CloudEventsHeaders.firebaseAuthUserDeleted:
            try await handleUserDeleted(req: req, headers: headers, authData: authData)
        default:
            // Already validated in parser, but handle defensively
            req.logger.warning("Unhandled event type", metadata: ["eventType": .string(headers.type)])
        }

        return .ok
    }

    /// Handles Firebase Auth user.v1.created events
    private func handleUserCreated(
        req: Request,
        headers: CloudEventsHeaders,
        authData: AuthEventData
    ) async throws {
        req.logger.info("User registered", metadata: [
            "userId": .string(authData.uid),
            "email": .string(authData.email ?? "(not provided)"),
            "displayName": .string(authData.displayName ?? "(not provided)"),
            "emailVerified": .stringConvertible(authData.emailVerified ?? false),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await req.deps.integrationEventChannel.publish(
            UserCreatedIntegrationEvent(
                // Stable across Eventarc redeliveries, so the inbox can dedup them.
                id: headers.integrationEventId,
                userId: authData.uid,
                email: authData.email,
                displayName: authData.displayName,
                registeredAt: headers.time,
                correlationId: RequestContext.traceId ?? TraceID(stringLiteral: req.id)
            )
        )
    }

    /// Handles Firebase Auth user.v1.deleted events
    private func handleUserDeleted(
        req: Request,
        headers: CloudEventsHeaders,
        authData: AuthEventData
    ) async throws {
        req.logger.info("User deleted", metadata: [
            "userId": .string(authData.uid),
            "email": .string(authData.email ?? "(not provided)"),
            "displayName": .string(authData.displayName ?? "(not provided)"),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await req.application.deps.integrationEventChannel.publish(
            UserDeletedIntegrationEvent(
                // Stable across Eventarc redeliveries, so the inbox can dedup them.
                id: headers.integrationEventId,
                userId: authData.uid,
                email: authData.email,
                displayName: authData.displayName,
                correlationId: RequestContext.traceId ?? TraceID(stringLiteral: req.id)
            )
        )
    }
}
