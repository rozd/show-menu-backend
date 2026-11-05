import Vapor

/// Catch-all guard for `/api/v1/plans/**`.
///
/// Registered on the admin-guarded group so that every path under `/plans` that no
/// real route matches answers 401/403 exactly like Node's `use()` guard, and 404 for
/// an authorized admin. The real `/plans` routes live in the Catalog module.
struct PlansGuardRouteV1: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("v1", "plans")
        plans.get("**") { req async throws -> Response in
            throw Abort(.notFound, reason: "Route \(req.url.path) not found")
        }
    }
}
