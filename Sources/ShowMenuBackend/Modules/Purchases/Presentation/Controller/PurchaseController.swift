import OpenAPIRuntime
import ShowMenuContracts
import Vapor

/// `purchaseSubscription` -> 200 `text/plain` invoice id (`invoice-...`).
/// `cancelPurchase` -> 200 `text/plain` `OK`.
/// Errors are typed and rendered by `HTTPErrorMiddleware`.
struct PurchaseController: Sendable {

    let purchaseFlow: PurchaseSubscriptionFlow
    let cancelPurchaseCommandHandler: CancelPurchaseCommandHandler

    func purchase(
        _ input: Operations.PurchaseSubscription.Input
    ) async throws -> Operations.PurchaseSubscription.Output {
        // `input.headers.idempotencyKey` is deliberately ignored: `IdempotencyKeyMiddleware` is
        // the source of truth for `Idempotency-Key` (it binds `RequestContext.idempotencyKey`).
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let invoiceId = try await purchaseFlow.run(PurchaseSubscriptionCommand(
            accountId: input.path.accountId,
            customerEmail: (RequestContext.principal as? FirebasePrincipal)?.email,
            payload: PurchasesWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .plainText(HTTPBody(invoiceId))))
    }

    func cancel(
        _ input: Operations.CancelPurchase.Input
    ) async throws -> Operations.CancelPurchase.Output {
        try await cancelPurchaseCommandHandler.handle(CancelPurchaseCommand(
            accountId: input.path.accountId,
            invoiceId: input.path.invoiceId,
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .plainText(HTTPBody("OK"))))
    }
}
