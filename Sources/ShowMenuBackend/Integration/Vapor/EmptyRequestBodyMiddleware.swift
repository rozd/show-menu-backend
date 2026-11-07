import HTTPTypes
import OpenAPIRuntime

/// Presents a zero-length request body to the generated deserializer as **no
/// body at all**.
///
/// The wire contract has one operation whose request body is `required: false`
/// (`handleEventarcEvent`). The generated deserializer treats a body as absent
/// only when the transport hands it `nil`, while `OpenAPIVapor` hands it an
/// **empty** `HTTPBody`, so a client that omits the body would reach JSON
/// decoding with zero bytes and fail there with a 400 on a request the contract
/// says is well-formed.
///
/// A `ServerMiddleware` is the only place that sees the body before the generated
/// code does. The check reads `HTTPBody.length`, which is metadata the transport
/// already knows (`Content-Length`), so the stream is never consumed; a body of
/// unknown length passes through untouched. For an operation whose body is
/// required an empty body is an error either way (400, "missing request body").
struct EmptyRequestBodyMiddleware: ServerMiddleware {

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let body, body.length == .known(0) else {
            return try await next(request, body, metadata)
        }
        return try await next(request, nil, metadata)
    }
}
