import Vapor

/// Plan routes (`/plans`). Register on the admin-guarded group, together with
/// `PlansGuardRouteV1`, whose `/plans/**` catch-all keeps guarding unmatched
/// paths. Static `features` is registered by `FeatureRouteV1` (POST/PUT) and
/// never collides with `GET /plans/:planId`'s method+shape except `GET
/// /plans/features`, which resolves to a plan lookup (404), as in Node.
struct PlanRouteV1: RouteCollection {
    private let controller: PlanController

    init(controller: PlanController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let plans = routes.grouped("v1", "plans")
        plans.get(use: controller.listPlans)
        plans.post(use: controller.createPlan)
        plans.get(":planId", use: controller.getPlan)
    }
}
