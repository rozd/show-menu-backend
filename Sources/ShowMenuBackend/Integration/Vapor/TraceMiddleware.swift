//
//  TraceMiddleware.swift
//  ShowMenuBackend
//
//  Binds a per-request correlation id to `RequestContext.traceId`.
//

import Vapor

// MARK: - Header names

extension HTTPHeaders.Name {

    /// The de-facto standard request-correlation header.
    static let xRequestId = HTTPHeaders.Name("X-Request-ID")

    /// Widely used alternative, accepted as a fallback.
    static let xCorrelationId = HTTPHeaders.Name("X-Correlation-ID")
}

// MARK: - Middleware

/// Establishes the request's correlation id and publishes it as
/// ``RequestContext/traceId`` for the duration of the request.
///
/// Everything downstream reads that task-local rather than being handed an id:
/// `CommandMetadata` stamps it on commands, integration events carry it as
/// `correlationId`, and outbox rows persist it — so one HTTP request can be
/// followed through commands, events and background publication. Install this
/// **first** in the middleware chain, before anything that logs or handles a
/// command.
///
/// The id is taken from the incoming request when the caller supplies one (an
/// upstream proxy, gateway or calling service), so a distributed trace is not
/// broken at this hop; otherwise a fresh one is generated. `header` and
/// `fallbackHeader` are configurable because the correlation header is a
/// deployment convention, not a standard — point them at whatever your ingress
/// sets (e.g. `traceparent`) without touching anything else.
struct TraceMiddleware: AsyncMiddleware {

    /// Primary header carrying an inbound correlation id.
    let header: HTTPHeaders.Name

    /// Consulted when `header` is absent.
    let fallbackHeader: HTTPHeaders.Name?

    /// Metadata key under which the id is attached to the request logger.
    let logMetadataKey: String

    init(
        header: HTTPHeaders.Name = .xRequestId,
        fallbackHeader: HTTPHeaders.Name? = .xCorrelationId,
        logMetadataKey: String = "traceId"
    ) {
        self.header = header
        self.fallbackHeader = fallbackHeader
        self.logMetadataKey = logMetadataKey
    }

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let inbound = req.headers.first(name: header)
            ?? fallbackHeader.flatMap { req.headers.first(name: $0) }

        let traceId: TraceID = inbound
            .map { TraceID(stringLiteral: $0.trimmingCharacters(in: .whitespaces)) }
            ?? .generate()

        req.logger[metadataKey: logMetadataKey] = .string(traceId.rawValue)

        return try await RequestContext.$traceId.withValue(traceId) {
            let start = ContinuousClock.now
            do {
                let response = try await next.respond(to: req)
                // Echo the id back so a client can correlate its own logs with ours.
                response.headers.replaceOrAdd(name: header, value: traceId.rawValue)
                log(req: req, statusCode: Int(response.status.code), start: start)
                return response
            } catch {
                // An error escaping here is rendered by Vapor's ErrorMiddleware;
                // log the request line anyway so the trace is not silently missing.
                log(req: req, statusCode: Int((error as? any AbortError)?.status.code ?? 500), start: start)
                throw error
            }
        }
    }

    private func log(req: Request, statusCode: Int, start: ContinuousClock.Instant) {
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18

        req.logger.log(
            level: statusCode >= 500 ? .error : .info,
            "\(req.method.rawValue) \(req.url.path) \(statusCode)",
            metadata: [
                "httpRequest": .dictionary([
                    "requestMethod": .string(req.method.rawValue),
                    "requestUrl": .string(req.url.string),
                    "status": .stringConvertible(statusCode),
                    "latency": .string(String(format: "%.6fs", seconds)),
                    "userAgent": .string(req.headers.first(name: .userAgent) ?? ""),
                    "remoteIp": .string(
                        req.headers.first(name: "X-Forwarded-For")
                            ?? req.remoteAddress?.ipAddress ?? ""
                    ),
                    "protocol": .string("HTTP/\(req.version.major).\(req.version.minor)"),
                ]),
            ]
        )
    }
}
