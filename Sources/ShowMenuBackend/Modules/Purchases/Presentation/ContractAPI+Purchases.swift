import ShowMenuContracts

/// Purchases' witnesses: purchase / cancel a purchase, and the public LiqPay callback.
extension ContractAPI {

    private var purchaseController: PurchaseController {
        PurchaseController(
            purchaseFlow: app.deps.purchaseSubscriptionFlow,
            cancelPurchaseCommandHandler: app.deps.cancelPurchaseCommandHandler
        )
    }

    func purchaseSubscription(
        _ input: Operations.PurchaseSubscription.Input
    ) async throws -> Operations.PurchaseSubscription.Output {
        try await purchaseController.purchase(input)
    }

    func cancelPurchase(
        _ input: Operations.CancelPurchase.Input
    ) async throws -> Operations.CancelPurchase.Output {
        try await purchaseController.cancel(input)
    }

    func handleLiqPayCallback(
        _ input: Operations.HandleLiqPayCallback.Input
    ) async throws -> Operations.HandleLiqPayCallback.Output {
        try await PaymentCallbackController(
            gateway: app.deps.paymentGateway,
            handler: app.deps.handleLiqPayCallbackCommandHandler,
            logger: app.logger
        ).liqpayCallback(input)
    }
}
