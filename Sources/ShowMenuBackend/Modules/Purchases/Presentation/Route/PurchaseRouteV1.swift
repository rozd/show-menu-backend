import Vapor

/// `/accounts/:accountId/purchases`. Register on the `authenticated` group.
struct PurchaseRouteV1: RouteCollection {
    private let controller: PurchaseController

    init(controller: PurchaseController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let purchases = routes.grouped("v1", "accounts", ":accountId", "purchases")
        purchases.post(use: controller.purchase)
    }
}
