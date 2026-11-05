import Vapor

struct GoogleCloudPlatformTraceMiddleware: AsyncMiddleware {

    let projectId: String

    func respond(
        to req: Request,
        chainingTo next: any AsyncResponder,
    ) async throws -> Response {
        let ctx: GoogleCloudPlatformTraceContext? =
            req.headers.first(name: "traceparent").flatMap { .init(traceparent: $0) } ??
            req.headers.first(name: "X-Cloud-Trace-Context").flatMap { .init(xCloudTrace: $0) }

        let traceId: TraceID
        if let ctx {
            traceId = TraceID(stringLiteral: ctx.traceId)
            req.logger[metadataKey: "gcp/trace"] = .string(ctx.traceResourceName(projectId: projectId))
            if let span = ctx.spanId {
                req.logger[metadataKey: "gcp/spanId"] = .string(span)
            }
            req.logger[metadataKey: "gcp/traceSampled"] = .stringConvertible(ctx.sampled)
        } else {
            traceId = .generate()
            req.logger[metadataKey: "gcp/trace"] = .string("projects/\(projectId)/traces/\(traceId.rawValue)")
        }

        return try await RequestContext.$traceId.withValue(traceId) {
            let start = ContinuousClock.now
            let response: Response
            do {
                response = try await next.respond(to: req)
            } catch {
                logHTTPRequest(req: req, statusCode: 500, start: start)
                throw error
            }
            logHTTPRequest(req: req, statusCode: Int(response.status.code), start: start)
            return response
        }
    }

    private func logHTTPRequest(req: Request, statusCode: Int, start: ContinuousClock.Instant) {
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18

        req.logger.log(
            level: statusCode >= 500 ? .error : .info,
            "\(req.method) \(req.url.path) \(statusCode)",
            metadata: [
                "gcp/httpRequest": .dictionary([
                    "requestMethod": .string(req.method.rawValue),
                    "requestUrl": .string(req.url.string),
                    "status": .stringConvertible(statusCode),
                    "latency": .string(String(format: "%.9fs", seconds)),
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

extension GoogleCloudPlatformTraceMiddleware {

    static func initFromEnvironment() throws -> GoogleCloudPlatformTraceMiddleware {
        guard let projectId = Environment.get("GCP_PROJECT_ID") else {
            throw GoogleCloudPlatformTraceMiddlewareError.missingProjectId
        }
        return GoogleCloudPlatformTraceMiddleware(projectId: projectId)
    }

}

enum GoogleCloudPlatformTraceMiddlewareError: Error {
    case missingProjectId
}

// MARK: - Trace Context Extraction

struct GoogleCloudPlatformTraceContext {
    let traceId: String
    let spanId: String?
    let sampled: Bool

    init(traceId: String, spanId: String?, sampled: Bool) {
        self.traceId = traceId
        self.spanId = spanId
        self.sampled = sampled
    }

    func traceResourceName(projectId: String) -> String {
        "projects/\(projectId)/traces/\(traceId)"
    }
}

extension GoogleCloudPlatformTraceContext {

    init?(traceparent header: String) {
        let parts = header.split(separator: "-")
        guard parts.count >= 4 else {
            return nil
        }
        self.init(
            traceId: String(parts[1]),
            spanId: String(parts[2]), // already 16-char hex
            sampled: (UInt8(String(parts[3]), radix: 16) ?? 0) & 0x01 == 1,
        )
    }

    init?(xCloudTrace header: String) {
        let parts = header.split(separator: "/", maxSplits: 1)
        guard let traceId = parts.first.map(String.init) else {
            return nil
        }
        var spanId: String? = nil
        var sampled = false
        if parts.count > 1 {
            let remainder = String(parts[1]).split(separator: ";", maxSplits: 1)
            if let decimal = remainder.first.flatMap({ UInt64(String($0)) }) {
                spanId = String(format: "%016x", decimal)   // decimal → 16-char hex
            }
            if remainder.count > 1 { sampled = String(remainder[1]).contains("o=1") }
        }
        self.init(traceId: traceId, spanId: spanId, sampled: sampled)
    }
}
