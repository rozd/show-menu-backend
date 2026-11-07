import OpenAPIRuntime
import Vapor

// MARK: - Envelope

/// The single error body for every HTTP failure (D4):
/// `{"error":{"code","message","details?"}}`.
struct ErrorEnvelope: Content, Equatable {

    struct Detail: Codable, Equatable, Sendable {
        let field: String?
        let message: String
    }

    struct Body: Codable, Equatable, Sendable {
        let code: String
        let message: String
        let details: [Detail]?
    }

    let error: Body
}

/// Opt-in status override for a `DomainError` that is neither a
/// `ValidationError` (422) nor a plain rule violation (409 default).
/// Conform in the domain-error enum; the domain stays Vapor-free by using the
/// status helpers below rather than importing HTTP concepts in logic.
protocol HTTPStatusHinted: Error {
    var httpStatusHint: HTTPResponseStatus { get }
}

// MARK: - Mapping

/// Pure error → HTTP mapping table (kept free of Vapor `Request` so it is
/// unit-testable).
struct HTTPErrorMapping: Equatable {
    let status: HTTPResponseStatus
    let code: String
    let message: String
    let details: [ErrorEnvelope.Detail]?
    /// `true` for failures that are server faults (logged at error level).
    var isServerFault: Bool { status.code >= 500 }

    init(_ status: HTTPResponseStatus, _ code: String, _ message: String, details: [ErrorEnvelope.Detail]? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
    }

    static let internalMessage = "Internal server error"

    static func map(_ error: any Error) -> HTTPErrorMapping {
        switch error {
        // The generated server wraps every handler / middleware / decoding failure in a
        // `ServerError`; the real error is `underlyingError` (a handler's thrown error, a
        // `DecodingError` for a malformed body, or the runtime's own error for a missing body /
        // parameter, which `OpenAPIRuntime` keeps `internal`).
        case let e as ServerError:
            let inner = map(e.underlyingError)
            // A runtime-originated 4xx (missing body, bad parameter, unsupported content type)
            // is not one of ours, so it fell through to the 500 default: map it by its status.
            if inner.status == .internalServerError, inner.code == "internal_error",
               e.underlyingError is any HTTPResponseConvertible, (400..<500).contains(e.httpStatus.code) {
                let status = HTTPResponseStatus(statusCode: e.httpStatus.code)
                return .init(status, code(for: status), e.causeDescription)
            }
            return inner

        // Domain / application layer
        case let e as ApplicationError:
            switch e {
            case let .notFound(entity, id): return .init(.notFound, "not_found", "\(entity) \(id) not found")
            case let .invalidInput(reason): return .init(.unprocessableEntity, "validation_failed", reason)
            }
        case let e as any HTTPStatusHinted:
            return .init(e.httpStatusHint, code(for: e.httpStatusHint), describe(e))
        case let e as any ValidationError:
            return .init(.unprocessableEntity, "validation_failed", describe(e))
        case let e as any DomainError:
            return .init(.conflict, "domain_rule_violation", describe(e))
        case let e as ConcurrencyError:
            return .init(.conflict, "version_conflict", describe(e))
        case let e as AuthorizationError:
            switch e {
            case let .denied(reason): return .init(.forbidden, "forbidden", reason)
            case .missingPrincipal: return .init(.unauthorized, "unauthorized", "Authentication required")
            }
        case let e as IdempotencyError:
            let code: String = switch e {
            case .malformedKey: "idempotency_key_invalid"
            case .requestInProgress: "request_in_progress"
            case .fingerprintMismatch: "idempotency_key_reused"
            case .corruptRecord: "internal_error"
            }
            if case .corruptRecord = e { return .init(.internalServerError, code, internalMessage) }
            return .init(e.status, code, e.reason)

        // Infrastructure
        case let e as FirestoreError:
            switch e {
            case .documentNotFound: return .init(.notFound, "not_found", "Resource not found")
            case .documentAlreadyExists: return .init(.conflict, "conflict", "Resource already exists")
            case .connectionFailed, .rateLimitExceeded, .serviceUnavailable, .transactionReturnedNil:
                return .init(.serviceUnavailable, "service_unavailable", "Service temporarily unavailable")
            case .authenticationFailed, .requestFailed:
                return .init(.internalServerError, "internal_error", internalMessage)
            }

        // Edge
        case let e as ValidationsError:
            let details = e.failures.filter(\.isFailure).map {
                ErrorEnvelope.Detail(field: $0.key.stringValue, message: $0.failureDescription ?? "is invalid")
            }
            return .init(.unprocessableEntity, "validation_failed", "Validation failed",
                         details: details.isEmpty ? nil : details)
        case let e as DecodingError:
            return .init(.badRequest, "bad_request", "Malformed request body",
                         details: [.init(field: path(of: e), message: decodingReason(e))])
        case let e as any AbortError:
            return .init(e.status, code(for: e.status), e.reason)
        default:
            return .init(.internalServerError, "internal_error", internalMessage)
        }
    }

    static func code(for status: HTTPResponseStatus) -> String {
        switch status.code {
        case 400: "bad_request"
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 405: "method_not_allowed"
        case 409: "conflict"
        case 412: "precondition_failed"
        case 413: "payload_too_large"
        case 415: "unsupported_media_type"
        case 422: "validation_failed"
        case 429: "too_many_requests"
        case 503: "service_unavailable"
        case 500...: "internal_error"
        default: "bad_request"
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func path(of error: DecodingError) -> String? {
        var keys: [any CodingKey]
        switch error {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c): keys = c.codingPath
        case let .keyNotFound(key, c): keys = c.codingPath + [key]
        @unknown default: return nil
        }
        let path = keys.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? nil : path
    }

    private static func decodingReason(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c): c.debugDescription
        case let .keyNotFound(key, _): "Missing required field '\(key.stringValue)'"
        @unknown default: "Invalid value"
        }
    }
}

// MARK: - Middleware

/// Replaces Vapor's default `ErrorMiddleware`: every thrown error (including the
/// router's own 404 for unknown paths) becomes the D4 envelope. Install with
/// `app.useErrorEnvelope()` so it is the only error middleware, not stacked.
struct HTTPErrorMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            return Self.response(for: error, on: request)
        }
    }

    /// A log-safe description. `ServerError`'s own description embeds the whole request, including
    /// the `Authorization` header, so log the operation and the underlying error instead.
    static func loggable(_ error: any Error) -> String {
        guard let serverError = error as? ServerError else { return String(describing: error) }
        return "\(serverError.operationID): \(loggable(serverError.underlyingError))"
    }

    static func response(for error: any Error, on request: Request) -> Response {
        let mapping = HTTPErrorMapping.map(error)
        let meta: Logger.Metadata = [
            "error": .string(loggable(error)),
            "status": .stringConvertible(mapping.status.code),
        ]
        if mapping.isServerFault {
            request.logger.error("Request failed", metadata: meta)
        } else {
            request.logger.debug("Request rejected", metadata: meta)
        }

        var headers = HTTPHeaders()
        if let abort = error as? any AbortError {
            headers = abort.headers
        }
        headers.contentType = .json
        headers.remove(name: .contentLength)

        let envelope = ErrorEnvelope(error: .init(code: mapping.code, message: mapping.message, details: mapping.details))
        let body = (try? JSONEncoder().encode(envelope)) ?? Data(#"{"error":{"code":"internal_error","message":"Internal server error"}}"#.utf8)
        return Response(status: mapping.status, headers: headers, body: .init(data: body))
    }
}

extension Application {
    /// Makes `HTTPErrorMiddleware` the sole error handler. Keeps every other
    /// middleware already installed (notably the Cloud Run trace middleware that
    /// `entrypoint` adds first), drops Vapor's default `ErrorMiddleware`, and
    /// inserts ours right after a leading trace middleware (else first), giving
    /// trace → error envelope → everything else.
    func useErrorEnvelope() {
        let existing = middleware.resolve().filter { !($0 is ErrorMiddleware) && !($0 is HTTPErrorMiddleware) }
        var rebuilt: [any Middleware] = existing
        let traceCount = existing.prefix { $0 is GoogleCloudPlatformTraceMiddleware }.count
        rebuilt.insert(HTTPErrorMiddleware(), at: traceCount)
        middleware = .init()
        for m in rebuilt { middleware.use(m) }
    }
}
