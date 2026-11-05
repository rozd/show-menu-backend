import Vapor

/// Catch-all guard for `/api/v1/plans/**`.
///
/// Registered on the admin-guarded group so that every path under `/plans` that no
/// real route matches answers 401/403 exactly like Node's `use()` guard, and 404 for
/// an authorized admin. The real `/plans` routes live in the Catalog module.
struct PlansGuardRouteV1: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("v1", "plans")
        // Every method, like Node's `use()` guard. Real routes (more specific) win.
        let notFound: @Sendable (Request) async throws -> Response = { req in
            throw Abort(.notFound, reason: "Route \(req.url.path) not found")
        }
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE] {
            plans.on(method, "**", use: notFound)
            plans.on(method, use: notFound)
        }
    }
}
