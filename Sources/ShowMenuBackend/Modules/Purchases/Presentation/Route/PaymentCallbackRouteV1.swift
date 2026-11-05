import Vapor

/// `/payments/liqpay/callback`. Register on the **public** group: LiqPay sends no token.
struct PaymentCallbackRouteV1: RouteCollection {
    private let controller: PaymentCallbackController

    init(controller: PaymentCallbackController) {
        self.controller = controller
    }

    func boot(routes: any RoutesBuilder) throws {
        let liqpay = routes.grouped("v1", "payments", "liqpay")
        liqpay.post("callback", use: controller.liqpayCallback)
    }
}
