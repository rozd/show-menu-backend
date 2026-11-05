import Vapor

/// Parser for CloudEvents v1.0 format webhooks from Eventarc
enum CloudEventsParser {
    /// Supported event types
    static let supportedEventTypes: Set<String> = [
        CloudEventsHeaders.firebaseAuthUserCreated,
        CloudEventsHeaders.firebaseAuthUserDeleted,
        CloudEventsHeaders.firestoreDocumentCreated,
    ]

    /// Parses and validates the CloudEvents headers of a webhook request
    /// (spec version, supported type, freshness). The body is decoded by the
    /// caller, because its shape depends on `headers.type`.
    /// - Throws: CloudEventsError or Vapor Abort if validation fails
    static func parseHeaders(_ request: Request) throws -> CloudEventsHeaders {
        // Parse and validate headers
        let headers = try CloudEventsHeaders.from(request)

        // Validate event type is supported
        guard supportedEventTypes.contains(headers.type) else {
            request.logger.warning("Unsupported event type received", metadata: [
                "eventType": .string(headers.type),
                "eventId": .string(headers.id)
            ])
            throw Abort(.badRequest, reason: "Unsupported event type: \(headers.type)")
        }

        // Validate timestamp is recent (prevents replay attacks)
        try headers.validateTimestamp()

        return headers
    }

    /// Parses and validates a Firebase Auth CloudEvents webhook request
    /// - Parameter request: The incoming HTTP request
    /// - Returns: Tuple of parsed headers and auth event data
    /// - Throws: CloudEventsError or Vapor Abort if validation fails
    static func parse(_ request: Request) async throws -> (headers: CloudEventsHeaders, data: AuthEventData) {
        let headers = try parseHeaders(request)

        // Parse request body
        let authData = try request.content.decode(AuthEventData.self)

        request.logger.debug("CloudEvent parsed successfully", metadata: [
            "eventId": .string(headers.id),
            "eventType": .string(headers.type),
            "userId": .string(authData.uid)
        ])

        return (headers, authData)
    }

    /// Checks if a request appears to be a CloudEvents webhook
    /// - Parameter request: The incoming HTTP request
    /// - Returns: True if request has CloudEvents headers
    static func isCloudEventsRequest(_ request: Request) -> Bool {
        request.headers.contains(name: "ce-specversion")
    }
}
