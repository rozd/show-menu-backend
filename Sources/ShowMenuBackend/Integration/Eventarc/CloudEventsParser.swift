import Vapor

/// Parser for CloudEvents v1.0 format webhooks from Eventarc
enum CloudEventsParser {
    /// Supported event types
    static let supportedEventTypes: Set<String> = [
        CloudEventsHeaders.firebaseAuthUserCreated,
        CloudEventsHeaders.firebaseAuthUserDeleted,
        CloudEventsHeaders.firestoreDocumentCreated,
    ]

    /// The raw `ce-*` header values of a webhook request, as the transport delivered them.
    struct RawHeaders: Sendable {
        var id: String?
        var source: String?
        var type: String?
        var specVersion: String?
        var subject: String?
        var time: String?

        init(
            id: String? = nil, source: String? = nil, type: String? = nil,
            specVersion: String? = nil, subject: String? = nil, time: String? = nil
        ) {
            self.id = id
            self.source = source
            self.type = type
            self.specVersion = specVersion
            self.subject = subject
            self.time = time
        }
    }

    /// Parses and validates the CloudEvents headers of a webhook request
    /// (spec version, supported type, freshness). The body is decoded by the
    /// caller, because its shape depends on `headers.type`.
    /// - Throws: CloudEventsError or Vapor Abort if validation fails
    static func parseHeaders(_ raw: RawHeaders, logger: Logger) throws -> CloudEventsHeaders {
        // Parse and validate headers
        let headers = try CloudEventsHeaders.from(
            specVersion: raw.specVersion, type: raw.type, source: raw.source,
            id: raw.id, time: raw.time, subject: raw.subject
        )

        // Validate event type is supported
        guard supportedEventTypes.contains(headers.type) else {
            logger.warning("Unsupported event type received", metadata: [
                "eventType": .string(headers.type),
                "eventId": .string(headers.id)
            ])
            throw Abort(.badRequest, reason: "Unsupported event type: \(headers.type)")
        }

        // Validate timestamp is recent (prevents replay attacks)
        try headers.validateTimestamp()

        return headers
    }

    /// A request is a CloudEvents webhook when it carries `ce-specversion`.
    static func isCloudEventsRequest(_ raw: RawHeaders) -> Bool {
        raw.specVersion != nil
    }
}
