import Vapor

/// `DELETE /accounts/:accountId/subscriptions/:subscriptionId`. Register on the `authenticated` group.
///
/// Node mounted this as a stub behind the auth guard: it did nothing and answered a JSON
/// `"OK"`. It is kept only so an unauthenticated call answers 401 (not 404) like Node;
/// subscriptions end through expiration, not through this endpoint.
struct SubscriptionCancelRouteV1: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let subscriptions = routes.grouped("v1", "accounts", ":accountId", "subscriptions")
        subscriptions.delete(":subscriptionId") { _ async throws -> Response in
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: try JSONEncoder().encode("OK")))
        }
    }
}
