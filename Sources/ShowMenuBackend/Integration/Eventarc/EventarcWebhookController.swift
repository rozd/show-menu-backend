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

        // Parse and validate the CloudEvents headers; the body shape depends on the type.
        let headers = try CloudEventsParser.parseHeaders(req)

        // Route to appropriate handler based on event type
        switch headers.type {
        case CloudEventsHeaders.firebaseAuthUserCreated:
            let authData = try req.content.decode(AuthEventData.self)
            try await handleUserCreated(req: req, headers: headers, authData: authData)
        case CloudEventsHeaders.firebaseAuthUserDeleted:
            let authData = try req.content.decode(AuthEventData.self)
            try await handleUserDeleted(req: req, headers: headers, authData: authData)
        case CloudEventsHeaders.firestoreDocumentCreated:
            let documentData = try req.content.decode(FirestoreEventData.self)
            try await handleDocumentCreated(req: req, headers: headers, documentData: documentData)
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
                photoURL: authData.photoUrl,
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

    /// Handles Firestore `document.v1.created` events (today: `accounts/{accountId}`).
    private func handleDocumentCreated(
        req: Request,
        headers: CloudEventsHeaders,
        documentData: FirestoreEventData
    ) async throws {
        let segments = documentData.path.split(separator: "/")
        guard segments.count == 2, segments[0] == "accounts" else {
            req.logger.warning("Ignoring Firestore event for an unhandled document path", metadata: [
                "path": .string(documentData.path),
                "eventId": .string(headers.id)
            ])
            return
        }
        guard let creator = documentData.data?.creator, !creator.isEmpty else {
            // 4xx: a malformed payload would never become valid on redelivery,
            // and the forwarder logs the status.
            throw Abort(.badRequest, reason: "accounts/\(documentData.documentId) event has no `creator`")
        }

        req.logger.info("Account created", metadata: [
            "accountId": .string(documentData.documentId),
            "creator": .string(creator),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await req.deps.integrationEventChannel.publish(
            AccountCreatedIntegrationEvent(
                // Stable across redeliveries, so the inboxed handlers dedup them.
                id: headers.integrationEventId,
                accountId: documentData.documentId,
                creatorId: creator,
                name: documentData.data?.name,
                createdAt: headers.time,
                correlationId: RequestContext.traceId ?? TraceID(stringLiteral: req.id)
            )
        )
    }
}
