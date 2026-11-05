import Foundation
import Logging

/// Applies one verified LiqPay callback (replaces the extension's `handlePaymentStatus` and
/// Node's `onInvoicePaymentStatusAdded` / `onCheckoutSessionUpdated` triggers).
///
/// No Policy Enforcement Point and no principal: the callback is public and its signature,
/// verified at the edge by the payment gateway, is the authentication.
///
/// Reads first (pinned client: no read after a write): invoice, order (through
/// `invoice.accountId` + `invoice.orderId`), session. Then writes: the audit document, the
/// invoice, the order, the session.
///
/// * Unknown invoice -> logged, nothing written, success (LiqPay must not retry forever).
/// * An invalid transition (e.g. a late `success` after `failure`, `unsubscribed` on a `paid`
///   invoice) never fails the callback: it is logged, the audit document is still written, and
///   the invoice, order and session are left exactly as they were (all-or-nothing, so the three
///   stay consistent).
/// * A repeated status is a no-op (S10); a further `success|subscribed` for a `paid` invoice
///   with a *new* payment is a subscription renewal: `Invoice.renew` raises `invoice.renewed`.
/// * In-flight statuses (`processing`, `wait_*`, ...) change no aggregate; they refresh a
///   `pending` session only (a terminal session is never moved back to `pending`).
/// * Missing session: skipped, not created (S12 precedent). Missing order: logged, the invoice
///   and the session are still updated.
struct HandleLiqPayCallbackUseCase: UseCase {
    struct Params: Sendable {
        let payload: HandleLiqPayCallbackCommand.Payload
    }

    let context: any UnitOfWorkContext
    let orderRepositoryFactory: RepositoryFactory<any OrderRepository>
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let sessionDataSourceFactory: DataSourceFactory<CheckoutSessionModel>
    let sessionMapper: CheckoutSessionMapper
    let auditStoreFactory: @Sendable (_ ctx: any UnitOfWorkContext) -> any InvoiceStatusAuditStore
    let logger: Logger

    func execute(params: Params) async throws {
        let payload = params.payload
        let metadata: Logger.Metadata = [
            "invoiceId": .string(payload.orderId), "status": .string(payload.status),
            "paymentId": .string(payload.paymentId ?? "-")
        ]
        logger.info("Executing HandleLiqPayCallbackUseCase", metadata: metadata)

        // MARK: Reads

        // Only our own invoice ids (`invoice-<uuid>`, Node and Vapor alike) are looked up.
        // Anything else (`/`, `.`/`..`, `__x__`, oversized) is not a valid document id
        // and would otherwise surface as a 500 that LiqPay retries forever.
        let invoiceRepository = invoiceRepositoryFactory(context)
        guard Self.isInvoiceDocumentId(payload.orderId),
              let invoice = try await invoiceRepository.fetch(byId: Invoice.Id(rawValue: payload.orderId))
        else {
            logger.warning("LiqPay callback for an unknown invoice, acknowledged without changes", metadata: metadata)
            return
        }

        let orderRepository = orderRepositoryFactory(context)
        let order = try await orderRepository.fetch(accountId: invoice.accountId, id: invoice.orderId)
        if order == nil {
            logger.warning("LiqPay callback: order not found", metadata: metadata.merging([
                "accountId": .string(invoice.accountId), "orderId": .string(invoice.orderId.rawValue)
            ]) { $1 })
        }

        let sessions = sessionDataSourceFactory("accounts/\(invoice.accountId)", context.transaction)
        let sessionModel = try await sessions.fetch(byId: invoice.id.rawValue)

        // MARK: Decide (in memory; nothing is persisted until the writes below)

        var invoiceChanged = false
        var orderChanged = false
        var rejected = false
        if let target = PaymentStatusMapping.invoiceTarget(for: payload.status) {
            do {
                let reference = payload.paymentReference
                switch target {
                case .paid:
                    if invoice.status == .paid {
                        invoiceChanged = try invoice.renew(transactionId: reference)
                    } else {
                        invoiceChanged = try invoice.pay(transactionId: reference)
                    }
                    orderChanged = try order?.complete(invoiceId: invoice.id) ?? false
                case .failed:
                    invoiceChanged = try invoice.fail()
                    orderChanged = try order?.fail(invoiceId: invoice.id) ?? false
                case .cancelled:
                    invoiceChanged = try invoice.cancel()
                    orderChanged = try order?.cancel(invoiceId: invoice.id) ?? false
                case .refunded:
                    invoiceChanged = try invoice.refund()
                    orderChanged = try order?.refund() ?? false
                case .pending:
                    break
                }
            } catch let error as any DomainError {
                // All-or-nothing: the in-memory aggregates are dropped, never persisted.
                rejected = true
                invoiceChanged = false
                orderChanged = false
                logger.error(
                    "LiqPay callback rejected by the state machine, acknowledged without changes",
                    metadata: metadata.merging(["reason": .string("\(error)")]) { $1 }
                )
            }
        }

        // MARK: Writes

        try await auditStoreFactory(context).append(invoiceId: invoice.id.rawValue, rawPayload: payload.rawPayload)

        if invoiceChanged { try await invoiceRepository.update(entity: invoice) }
        if orderChanged, let order { try await orderRepository.update(entity: order) }

        guard !rejected else { return }
        guard let sessionModel else {
            logger.notice("Checkout session not found, nothing to update", metadata: metadata)
            return
        }
        let current = sessionMapper.toEntity(model: sessionModel, accountId: invoice.accountId)
        let mapped = PaymentStatusMapping.sessionStatus(for: payload.status)
        guard mapped != .pending || current.status == .pending else { return }
        try await sessions.update(model: sessionMapper.toModel(entity: CheckoutSession(
            invoiceId: current.invoiceId, accountId: invoice.accountId, orderId: current.orderId,
            status: mapped, paymentPageURL: current.paymentPageURL,
            transactionId: payload.paymentReference ?? current.transactionId,
            // An error exists iff `err_code` is set (extension parity); a later callback replaces it.
            error: payload.errorCode.map {
                CheckoutSessionError(code: $0, message: payload.errorDescription, details: payload.info)
            }
        )))
    }
}

extension HandleLiqPayCallbackUseCase {
    /// `invoice-` prefix, no `/`, and within Firestore's 1500-byte document-id limit.
    static func isInvoiceDocumentId(_ id: String) -> Bool {
        id.hasPrefix(Invoice.Id.prefix) && !id.contains("/") && id.utf8.count <= 1500
    }
}
