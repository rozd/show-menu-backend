import Vapor

/// `POST /api/v1/accounts/:accountId/purchases` -> 200 `text/plain` invoice id (`invoice-...`).
/// `DELETE /api/v1/accounts/:accountId/purchases/:invoiceId` -> 200 `text/plain` `OK`.
/// Errors are typed and rendered by `HTTPErrorMiddleware`.
struct PurchaseController: Sendable {

    let purchaseFlow: PurchaseSubscriptionFlow
    let cancelPurchaseCommandHandler: CancelPurchaseCommandHandler

    @Sendable
    func purchase(req: Request) async throws -> String {
        guard let accountId = req.parameters.get("accountId") else {
            throw Abort(.badRequest, reason: "Missing accountId parameter")
        }
        let payload = try req.content.decode(PurchaseSubscriptionCommand.Payload.self)
        return try await purchaseFlow.run(PurchaseSubscriptionCommand(
            accountId: accountId,
            customerEmail: (RequestContext.principal as? FirebasePrincipal)?.email,
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }

    @Sendable
    func cancel(req: Request) async throws -> String {
        guard let accountId = req.parameters.get("accountId") else {
            throw Abort(.badRequest, reason: "Missing accountId parameter")
        }
        guard let invoiceId = req.parameters.get("invoiceId") else {
            throw Abort(.badRequest, reason: "Missing invoiceId parameter")
        }
        try await cancelPurchaseCommandHandler.handle(CancelPurchaseCommand(
            accountId: accountId,
            invoiceId: invoiceId,
            metadata: CommandMetadata(req: req)
        ))
        return "OK"
    }
}
