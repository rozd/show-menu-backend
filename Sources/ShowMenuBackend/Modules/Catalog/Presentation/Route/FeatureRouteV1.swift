import Vapor

/// Feature routes live under `/plans/features` (Node's plans router). Register on
/// the admin-guarded group. `PlansGuardRouteV1`'s `/plans/**` catch-all keeps
/// guarding unmatched paths; Vapor prefers these more specific routes.
struct FeatureRouteV1: RouteCollection {
    private let controller: FeatureController

    init(controller: FeatureController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let features = routes.grouped("v1", "plans", "features")
        features.post(use: controller.createFeature)
        features.put(":featureId", use: controller.updateFeature)
    }
}
