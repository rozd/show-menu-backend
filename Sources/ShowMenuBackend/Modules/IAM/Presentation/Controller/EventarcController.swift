import Foundation
import OpenAPIRuntime
import ShowMenuContracts
import Vapor

/// Serves `handleEventarcEvent`: CloudEvents binary-mode deliveries forwarded from Firebase Auth
/// and Firestore. Authentication (Google OIDC) has already happened in `ContractAccessMiddleware`.
///
/// Lives in IAM's Presentation layer because the user-lifecycle events are IAM's, but it also
/// raises the Firestore `accounts/{id}` created event (consumed by Accounts and IAM): the
/// controller only translates the CloudEvent into an integration event and publishes it.
struct EventarcController: Sendable {

    let app: Application

    private var logger: Logger { app.logger }

    /// `POST /api/v1/events/eventarc` → 200, empty body. No CloudEvents headers → 200, ignored.
    func handleEventarcEvent(
        _ input: Operations.HandleEventarcEvent.Input
    ) async throws -> Operations.HandleEventarcEvent.Output {
        let raw = CloudEventsParser.RawHeaders(
            id: input.headers.ceId,
            source: input.headers.ceSource,
            type: input.headers.ceType,
            specVersion: input.headers.ceSpecversion,
            subject: input.headers.ceSubject,
            time: input.headers.ceTime
        )

        // Check if this is a CloudEvents request
        guard CloudEventsParser.isCloudEventsRequest(raw) else {
            // Not a CloudEvents request - this might be a health check or other traffic
            logger.debug("Non-CloudEvents request to webhook endpoint")
            return .ok(.init())
        }

        // Parse and validate the CloudEvents headers; the body shape depends on the type.
        let headers = try CloudEventsParser.parseHeaders(raw, logger: logger)

        // Route to appropriate handler based on event type
        switch headers.type {
        case CloudEventsHeaders.firebaseAuthUserCreated:
            try await handleUserCreated(headers: headers, authData: try decodeBody(input, as: AuthEventData.self))
        case CloudEventsHeaders.firebaseAuthUserDeleted:
            try await handleUserDeleted(headers: headers, authData: try decodeBody(input, as: AuthEventData.self))
        case CloudEventsHeaders.firestoreDocumentCreated:
            try await handleDocumentCreated(headers: headers, documentData: try decodeBody(input, as: FirestoreEventData.self))
        default:
            // Already validated in parser, but handle defensively
            logger.warning("Unhandled event type", metadata: ["eventType": .string(headers.type)])
        }

        return .ok(.init())
    }

    /// Re-encodes the free-form JSON body and decodes the shape chosen by `ce-type`.
    /// A missing or ill-typed body is a 400 (`DecodingError`).
    private func decodeBody<T: Decodable>(
        _ input: Operations.HandleEventarcEvent.Input,
        as type: T.Type
    ) throws -> T {
        guard case let .json(payload)? = input.body else {
            throw Abort(.badRequest, reason: "Missing event data")
        }
        let data = try JSONEncoder().encode(payload.additionalProperties)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Handles Firebase Auth user.v1.created events
    private func handleUserCreated(headers: CloudEventsHeaders, authData: AuthEventData) async throws {
        logger.info("User registered", metadata: [
            "userId": .string(authData.uid),
            "email": .string(authData.email ?? "(not provided)"),
            "displayName": .string(authData.displayName ?? "(not provided)"),
            "emailVerified": .stringConvertible(authData.emailVerified ?? false),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await app.deps.integrationEventChannel.publish(
            UserCreatedIntegrationEvent(
                // Stable across Eventarc redeliveries, so the inbox can dedup them.
                id: headers.integrationEventId,
                userId: authData.uid,
                email: authData.email,
                displayName: authData.displayName,
                photoURL: authData.photoUrl,
                registeredAt: headers.time,
                correlationId: RequestContext.traceId ?? TraceID()
            )
        )
    }

    /// Handles Firebase Auth user.v1.deleted events
    private func handleUserDeleted(headers: CloudEventsHeaders, authData: AuthEventData) async throws {
        logger.info("User deleted", metadata: [
            "userId": .string(authData.uid),
            "email": .string(authData.email ?? "(not provided)"),
            "displayName": .string(authData.displayName ?? "(not provided)"),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await app.deps.integrationEventChannel.publish(
            UserDeletedIntegrationEvent(
                // Stable across Eventarc redeliveries, so the inbox can dedup them.
                id: headers.integrationEventId,
                userId: authData.uid,
                email: authData.email,
                displayName: authData.displayName,
                correlationId: RequestContext.traceId ?? TraceID()
            )
        )
    }

    /// Handles Firestore `document.v1.created` events (today: `accounts/{accountId}`).
    private func handleDocumentCreated(headers: CloudEventsHeaders, documentData: FirestoreEventData) async throws {
        let segments = documentData.path.split(separator: "/")
        guard segments.count == 2, segments[0] == "accounts" else {
            logger.warning("Ignoring Firestore event for an unhandled document path", metadata: [
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

        logger.info("Account created", metadata: [
            "accountId": .string(documentData.documentId),
            "creator": .string(creator),
            "eventId": .string(headers.id),
            "eventTime": .string(ISO8601DateFormatter().string(from: headers.time))
        ])

        await app.deps.integrationEventChannel.publish(
            AccountCreatedIntegrationEvent(
                // Stable across redeliveries, so the inboxed handlers dedup them.
                id: headers.integrationEventId,
                accountId: documentData.documentId,
                creatorId: creator,
                name: documentData.data?.name,
                createdAt: headers.time,
                correlationId: RequestContext.traceId ?? TraceID()
            )
        )
    }
}
