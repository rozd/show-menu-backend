import Foundation
import Logging

/// Opens the hosted payment page for a freshly placed purchase and records the outcome on
/// the checkout session. Runs **after** the purchase transaction has committed, because the
/// external gateway call must stay outside any transaction.
///
/// * success: the pending session gets its `paymentPageURL`;
/// * failure (roadmap bug 4: Node never failed the order): session -> `failure` with the
///   error fields, invoice -> `failed`, order -> `failed`, then the original error is rethrown
///   (the edge renders `PaymentGatewayError` as 502/503). Failing the invoice too keeps the
///   pair consistent with S13's mapping (the order follows the invoice) — a pending invoice
///   behind a failed order would never receive a callback.
///
/// Idempotent: a session that is no longer `pending`, or already has its URL, is left alone,
/// so replaying the purchase (same `Idempotency-Key`) after a crash between commit and
/// checkout finishes the job, and a replay after success does nothing.
struct CheckoutInitiator: Sendable {

    static let failureCode = "CHECKOUT_FAILED"

    let unitOfWork: any UnitOfWork
    let gateway: any PaymentGateway
    let sessionDataSourceFactory: DataSourceFactory<CheckoutSessionModel>
    let sessionMapper: CheckoutSessionMapper
    let invoiceDataSourceFactory: DataSourceFactory<InvoiceModel>
    let invoiceMapper: InvoiceMapper
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let orderRepositoryFactory: RepositoryFactory<any OrderRepository>
    /// Non-transactional handle for the reads that precede the gateway call.
    let directTransaction: @Sendable () -> any Sendable
    let logger: Logger

    func start(accountId: String, invoiceId: String) async throws {
        let prefix = "accounts/\(accountId)"
        guard let session = try await sessionDataSourceFactory(prefix, directTransaction()).fetch(byId: invoiceId),
              session.status == .pending, session.paymentPageURL == nil
        else {
            logger.debug("Checkout already started or not pending, skipping", metadata: ["invoiceId": .string(invoiceId)])
            return
        }
        guard let invoiceModel = try await invoiceDataSourceFactory("", directTransaction()).fetch(byId: invoiceId) else {
            throw ApplicationError.notFound(entity: "Invoice", id: Invoice.Id(rawValue: invoiceId))
        }
        let invoice = try invoiceMapper.toEntity(model: invoiceModel)

        let url: URL
        do {
            url = try await gateway.checkout(try invoice.checkoutRequest())
        } catch {
            logger.error("Checkout failed", metadata: [
                "invoiceId": .string(invoiceId), "error": .string(String(describing: error))
            ])
            // The gateway error is what the client must see; a failure to record it
            // is logged, not surfaced (the session stays pending until S12 cancel).
            do {
                try await recordFailure(accountId: accountId, invoiceId: invoiceId, error: error)
            } catch let recordError {
                logger.error("Recording checkout failure failed", metadata: [
                    "invoiceId": .string(invoiceId), "error": .string(String(describing: recordError))
                ])
            }
            throw error
        }
        try await recordPage(accountId: accountId, invoiceId: invoiceId, url: url)
    }

    private func recordPage(accountId: String, invoiceId: String, url: URL) async throws {
        let prefix = "accounts/\(accountId)"
        let factory = sessionDataSourceFactory
        let mapper = sessionMapper
        try await unitOfWork.execute { ctx in
            let sessions = factory(prefix, ctx.transaction)
            guard let model = try await sessions.fetch(byId: invoiceId), model.status == .pending else {
                return  // cancelled/finished meanwhile: do not resurrect it with a page
            }
            var session = mapper.toEntity(model: model, accountId: accountId)
            session = CheckoutSession(
                invoiceId: session.invoiceId, accountId: accountId, orderId: session.orderId,
                status: .pending, paymentPageURL: url.absoluteString,
                transactionId: session.transactionId, error: nil
            )
            try await sessions.update(model: mapper.toModel(entity: session))
        }
    }

    private func recordFailure(accountId: String, invoiceId: String, error: any Error) async throws {
        let prefix = "accounts/\(accountId)"
        let factory = sessionDataSourceFactory
        let mapper = sessionMapper
        let invoices = invoiceRepositoryFactory
        let orders = orderRepositoryFactory
        let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        try await unitOfWork.execute { ctx in
            // Reads first.
            let sessions = factory(prefix, ctx.transaction)
            let model = try await sessions.fetch(byId: invoiceId)
            let invoiceRepository = invoices(ctx)
            let orderRepository = orders(ctx)
            let invoice = try await invoiceRepository.fetch(byId: Invoice.Id(rawValue: invoiceId))
            var order: Order?
            if let invoice {
                order = try await orderRepository.fetch(accountId: accountId, id: invoice.orderId)
            }

            // Then writes.
            if let invoice, try invoice.fail() {
                try await invoiceRepository.update(entity: invoice)
            }
            if let invoice, let order, try order.fail(invoiceId: invoice.id) {
                try await orderRepository.update(entity: order)
            }
            if let model, model.status == .pending {
                let current = mapper.toEntity(model: model, accountId: accountId)
                try await sessions.update(model: mapper.toModel(entity: CheckoutSession(
                    invoiceId: current.invoiceId, accountId: accountId, orderId: current.orderId,
                    status: .failure, paymentPageURL: current.paymentPageURL, transactionId: current.transactionId,
                    error: CheckoutSessionError(code: Self.failureCode, message: message, details: nil)
                )))
            }
        }
    }
}

/// The purchase use case end to end: place the order (idempotent, one transaction), then
/// open the payment page outside it. Returns the invoice id.
struct PurchaseSubscriptionFlow: Sendable {
    let purchase: PurchaseSubscriptionCommandHandler
    let checkout: CheckoutInitiator

    func run(_ command: PurchaseSubscriptionCommand) async throws -> String {
        let invoiceId = try await purchase.handle(command)
        try await checkout.start(accountId: command.accountId, invoiceId: invoiceId)
        return invoiceId
    }
}
