import Vapor

/// Temporary `/api/v1/plans` placeholder (until S05 brings the Catalog module).
///
/// Registered on the admin-guarded group so that `GET /plans` and every
/// unmatched path beneath it answer 401/403 exactly like Node's `use()` guard,
/// and 404 for an authorized admin.
struct PlansGuardRouteV1: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("v1", "plans")
        plans.get { _ async -> [String] in [] }
        plans.get("**") { req async throws -> Response in
            throw Abort(.notFound, reason: "Route \(req.url.path) not found")
        }
    }
}
