import Vapor

// MARK: - Request: read the Idempotency-Key header

extension Request {

    /// The validated `Idempotency-Key` header, if present.
    ///
    /// Returns `nil` when the header is absent (the request runs without
    /// de-duplication); throws ``IdempotencyError/malformedKey(_:)`` when the
    /// header is present but invalid, so a client bug surfaces as `400` rather
    /// than silently disabling idempotency.
    func idempotencyKey() throws -> IdempotencyKey? {
        guard let raw = headers.first(name: "Idempotency-Key") else { return nil }
        return try IdempotencyKey(raw)
    }
}

// MARK: - Middleware: lift the key into RequestContext

/// Extracts the `Idempotency-Key` at the edge and binds it to
/// `RequestContext.idempotencyKey` for the duration of the request, so the
/// command pipeline's ``IdempotentCommandHandler`` can read it as request-scoped
/// metadata (never as a field on a command DTO). Mirrors how
/// `GoogleCloudPlatformTraceMiddleware` binds `RequestContext.traceId`.
struct IdempotencyKeyMiddleware: AsyncMiddleware {

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let key = try req.idempotencyKey() else {
            return try await next.respond(to: req)
        }
        return try await RequestContext.$idempotencyKey.withValue(key) {
            try await next.respond(to: req)
        }
    }
}

// MARK: - Edge status mapping

/// Renders idempotency failures as HTTP statuses at the boundary. Keeping the
/// mapping here (not in `Lib`) preserves the primitives' transport-independence,
/// while letting Vapor's error middleware render the right status automatically.
extension IdempotencyError: AbortError {

    var status: HTTPResponseStatus {
        switch self {
        case .malformedKey:        return .badRequest          // 400
        case .requestInProgress:   return .conflict            // 409
        case .fingerprintMismatch: return .unprocessableEntity // 422
        case .corruptRecord:       return .internalServerError // 500
        }
    }

    var reason: String {
        switch self {
        case .malformedKey:
            return "Invalid Idempotency-Key header"
        case .requestInProgress:
            return "A request with this Idempotency-Key is already in progress; retry shortly"
        case .fingerprintMismatch:
            return "Idempotency-Key was reused with a different request body"
        case .corruptRecord:
            return "Stored idempotency record is corrupt"
        }
    }
}
