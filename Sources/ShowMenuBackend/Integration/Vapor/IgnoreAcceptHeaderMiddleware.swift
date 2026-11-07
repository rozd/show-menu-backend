import HTTPTypes
import OpenAPIRuntime

/// Drops the request's `Accept` header before the generated server sees it.
///
/// The generated serializer validates `Accept` against the documented response content type
/// **after the handler has run**, answering 406 on a mismatch. On an operation with side
/// effects that is the worst order: `purchaseSubscription` would commit the purchase and then
/// lose the invoice id behind a 406. Every operation in the contract documents exactly one
/// response content type per status, so there is nothing for `Accept` to negotiate; ignoring
/// it is also what the hand-written Vapor routes (and the Node backend before them) did.
///
/// If the contract ever offers two representations of one response, replace this with real
/// negotiation that runs **before** the handler.
struct IgnoreAcceptHeaderMiddleware: ServerMiddleware {

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.accept] = nil
        return try await next(request, body, metadata)
    }
}
