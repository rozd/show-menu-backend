import Crypto
import Vapor

/// Parsed CloudEvents v1.0 headers from Eventarc webhooks
/// See: https://cloudevents.io/ and https://cloud.google.com/eventarc/docs/cloudevents
struct CloudEventsHeaders: Sendable {
    /// CloudEvents specification version (always "1.0")
    let specVersion: String

    /// Event type (e.g., "google.firebase.auth.user.v1.created")
    let type: String

    /// Event source URI (e.g., "//firebase.googleapis.com/projects/{project}")
    let source: String

    /// Unique event identifier
    let id: String

    /// Event timestamp
    let time: Date

    /// Optional event subject
    let subject: String?

    /// Required CloudEvents header names
    static let requiredHeaders = [
        "ce-specversion",
        "ce-type",
        "ce-source",
        "ce-id",
        "ce-time"
    ]

    /// Firebase Auth user created event type
    static let firebaseAuthUserCreated = "google.firebase.auth.user.v1.created"

    /// Firebase Auth user deleted event type
    static let firebaseAuthUserDeleted = "google.firebase.auth.user.v1.deleted"
}

// MARK: - Parsing

extension CloudEventsHeaders {
    /// Creates CloudEventsHeaders from HTTP request headers
    /// - Parameter request: The incoming HTTP request
    /// - Throws: CloudEventsError if required headers are missing or invalid
    static func from(_ request: Request) throws -> CloudEventsHeaders {
        // Extract required headers
        guard let specVersion = request.headers.first(name: "ce-specversion") else {
            throw CloudEventsError.missingHeader("ce-specversion")
        }

        guard specVersion == "1.0" else {
            throw CloudEventsError.invalidSpecVersion(specVersion)
        }

        guard let type = request.headers.first(name: "ce-type") else {
            throw CloudEventsError.missingHeader("ce-type")
        }

        guard let source = request.headers.first(name: "ce-source") else {
            throw CloudEventsError.missingHeader("ce-source")
        }

        guard let id = request.headers.first(name: "ce-id") else {
            throw CloudEventsError.missingHeader("ce-id")
        }

        guard let timeString = request.headers.first(name: "ce-time") else {
            throw CloudEventsError.missingHeader("ce-time")
        }

        // Parse RFC3339 timestamp (with or without fractional seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Try with fractional seconds first, then without
        let time: Date
        if let parsed = formatter.date(from: timeString) {
            time = parsed
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let parsed = formatter.date(from: timeString) else {
                throw CloudEventsError.invalidTimeFormat(timeString)
            }
            time = parsed
        }

        // Optional subject header
        let subject = request.headers.first(name: "ce-subject")

        return CloudEventsHeaders(
            specVersion: specVersion,
            type: type,
            source: source,
            id: id,
            time: time,
            subject: subject
        )
    }
}

// MARK: - Validation

extension CloudEventsHeaders {
    /// Validates the event is not stale (within acceptable time window)
    /// - Parameter maxAge: Maximum age in seconds (default: 5 minutes)
    /// - Throws: CloudEventsError.staleEvent if event is too old
    func validateTimestamp(maxAge: TimeInterval = 300) throws {
        let age = Date().timeIntervalSince(time)
        if age > maxAge {
            throw CloudEventsError.staleEvent(age: age, maxAge: maxAge)
        }
    }

    /// A stable `IntegrationEvent.id` for this CloudEvent, derived from
    /// `source` + `id`.
    ///
    /// The CloudEvents spec makes the (`source`, `id`) pair unique per distinct
    /// event, and a redelivery of the same event carries the same pair. Deriving
    /// the integration event id from it (instead of minting a fresh `UUID()` per
    /// HTTP request) is what lets an ``InboxedCommandHandler`` recognise an
    /// Eventarc redelivery as a duplicate.
    ///
    /// Name-based: SHA-256 over `source` U+0000 `id`, truncated to 128 bits and
    /// stamped as an RFC 9562 version-8 (custom) UUID with the RFC 4122 variant.
    var integrationEventId: UUID {
        let digest = Array(SHA256.hash(data: Data("\(source)\u{0}\(id)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Checks if this is a Firebase Auth user created event
    var isUserCreatedEvent: Bool {
        type == Self.firebaseAuthUserCreated
    }

    /// Checks if this is a Firebase Auth user deleted event
    var isUserDeletedEvent: Bool {
        type == Self.firebaseAuthUserDeleted
    }
}

// MARK: - Errors

enum CloudEventsError: Error, LocalizedError, AbortError {
    case missingHeader(String)
    case invalidSpecVersion(String)
    case invalidTimeFormat(String)
    case staleEvent(age: TimeInterval, maxAge: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .missingHeader(let header):
            return "Missing required CloudEvents header: \(header)"
        case .invalidSpecVersion(let version):
            return "Invalid CloudEvents spec version: \(version). Expected 1.0"
        case .invalidTimeFormat(let value):
            return "Invalid timestamp format: \(value). Expected RFC3339"
        case .staleEvent(let age, let maxAge):
            return "Event is too old: \(Int(age))s > \(Int(maxAge))s"
        }
    }

    var status: HTTPResponseStatus {
        switch self {
        case .missingHeader, .invalidSpecVersion, .invalidTimeFormat:
            return .badRequest
        case .staleEvent:
            return .badRequest
        }
    }
}
