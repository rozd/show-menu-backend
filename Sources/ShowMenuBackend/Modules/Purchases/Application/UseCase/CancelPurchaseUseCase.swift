import Foundation
import Logging

/// Cancels a purchase: invoice -> `cancelled`, order -> `cancelled`, checkout session ->
/// `cancelled`, all in one transaction (Node `CancelPurchaseUseCase`, with its bugs fixed:
/// the order is loaded through `invoice.orderId`, not the invoice id, and the session is
/// written at the real `accounts/{accountId}/checkout-sessions/{invoiceId}` path).
///
/// The UseCase is the Policy Enforcement Point: the account membership is checked right
/// after the account and the principal's permission document are read, before any decision
/// or write. Reads precede writes (pinned client rule).
///
/// * Unknown invoice, or one that belongs to another account -> 404 (never leaks existence).
/// * Order missing -> 404.
/// * Already `cancelled` -> idempotent no-op, 200 (same-status transitions return `false`).
/// * `paid` / `failed` / `refunded` invoice (or an order that cannot be cancelled) ->
///   ``InvalidStatusTransitionError`` (409).
/// * Session missing (never created, or not written yet): skipped, not created.
///
/// The `checkout_locks` marker is not touched: a `cancelled` session frees the account.
struct CancelPurchaseUseCase: UseCase {
    struct Params: Sendable {
        let accountId: String
        let invoiceId: String
    }

    let context: any UnitOfWorkContext
    let accountDataSourceFactory: DataSourceFactory<AccountModel>
    let accountMapper: AccountMapper
    let permissionStoreFactory: @Sendable (_ ctx: any UnitOfWorkContext) -> any AccountPermissionStore
    let ability: AccountMemberAbility
    let orderRepositoryFactory: RepositoryFactory<any OrderRepository>
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let sessionDataSourceFactory: DataSourceFactory<CheckoutSessionModel>
    let sessionMapper: CheckoutSessionMapper
    let logger: Logger

    func execute(params: Params) async throws {
        logger.info("Executing CancelPurchaseUseCase", metadata: [
            "accountId": .string(params.accountId),
            "invoiceId": .string(params.invoiceId)
        ])

        guard let principal = RequestContext.principal else {
            throw AuthorizationError.missingPrincipal
        }

        // MARK: Reads

        guard let accountModel = try await accountDataSourceFactory("", context.transaction)
            .fetch(byId: params.accountId)
        else {
            throw AccountNotFoundError(accountId: params.accountId)
        }
        let account = try accountMapper.toEntity(model: accountModel)
        let permission = try await permissionStoreFactory(context)
            .fetch(accountId: account.id, userId: principal.id)

        // Policy Enforcement Point.
        let membership = AccountMembership(account: account, hasPermissionDocument: permission != nil)
        if case .denied(let reason) = ability.evaluate(principal: principal, subject: membership) {
            logger.notice("CancelPurchaseUseCase denied", metadata: [
                "accountId": .string(account.id),
                "principal": .string(principal.id),
                "reason": .string(reason)
            ])
            throw AuthorizationError.denied(reason: reason)
        }

        let invoiceId = Invoice.Id(rawValue: params.invoiceId)
        let invoiceRepository = invoiceRepositoryFactory(context)
        guard let invoice = try await invoiceRepository.fetch(byId: invoiceId), invoice.accountId == account.id else {
            throw ApplicationError.notFound(entity: "Invoice", id: invoiceId)
        }

        let orderRepository = orderRepositoryFactory(context)
        guard let order = try await orderRepository.fetch(accountId: account.id, id: invoice.orderId) else {
            throw ApplicationError.notFound(entity: "Order", id: invoice.orderId)
        }

        let sessions = sessionDataSourceFactory("accounts/\(account.id)", context.transaction)
        let sessionModel = try await sessions.fetch(byId: params.invoiceId)

        // MARK: Writes

        // Invoice first: a paid / failed / refunded invoice is rejected before anything changes.
        if try invoice.cancel() {
            try await invoiceRepository.update(entity: invoice)
        }
        if try order.cancel(invoiceId: invoice.id) {
            try await orderRepository.update(entity: order)
        }

        if let sessionModel {
            if sessionModel.status != .cancelled {
                let current = sessionMapper.toEntity(model: sessionModel, accountId: account.id)
                try await sessions.update(model: sessionMapper.toModel(entity: CheckoutSession(
                    invoiceId: current.invoiceId, accountId: account.id, orderId: current.orderId,
                    status: .cancelled, paymentPageURL: current.paymentPageURL,
                    transactionId: current.transactionId, error: current.error
                )))
            }
        } else {
            logger.notice("Checkout session not found, nothing to cancel", metadata: [
                "accountId": .string(account.id), "invoiceId": .string(params.invoiceId)
            ])
        }
    }
}
