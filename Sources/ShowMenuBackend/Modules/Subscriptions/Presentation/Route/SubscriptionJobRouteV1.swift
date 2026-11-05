import Vapor

/// `/subscriptions/jobs/*`. Register on a group guarded by `SchedulerAuthMiddleware`.
struct SubscriptionJobRouteV1: RouteCollection {
    private let controller: SubscriptionJobController

    init(controller: SubscriptionJobController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let jobs = routes.grouped("v1", "subscriptions", "jobs")
        jobs.post("check-expired", use: controller.checkExpired)
    }
}
