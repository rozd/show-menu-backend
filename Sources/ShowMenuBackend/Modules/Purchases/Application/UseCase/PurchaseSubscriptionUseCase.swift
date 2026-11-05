import FirestoreAPI
import Foundation
import Logging

/// Places a subscription purchase: Order + Invoice + a `pending` checkout session, in one
/// transaction (Node `PurchaseSubscriptionUseCase`, plus the membership check and the
/// session, which the LiqPay extension used to create).
///
/// The UseCase is the Policy Enforcement Point: the account membership is checked right
/// after the account and its permission document are read, before anything else is
/// decided or written. The gateway checkout is **not** done here (the external call must
/// stay outside the transaction, see ``CheckoutInitiator``).
///
/// Read/write order matters (the pinned client forbids reads after writes in a
/// transaction, and cannot run queries inside one): every read below precedes the first
/// write; the pending-session scan is a *direct* (non-transactional) query.
struct PurchaseSubscriptionUseCase: UseCase {
    struct Params: Sendable {
        let accountId: String
        let customerEmail: String?
        let payload: PurchaseSubscriptionCommand.Payload
    }

    let context: any UnitOfWorkContext
    let accountDataSourceFactory: DataSourceFactory<AccountModel>
    let accountMapper: AccountMapper
    let permissionStoreFactory: @Sendable (_ ctx: any UnitOfWorkContext) -> any AccountPermissionStore
    let ability: AccountMemberAbility
    let planRepositoryFactory: RepositoryFactory<any PlanRepository>
    let userRepositoryFactory: RepositoryFactory<any UserRepository>
    let orderRepositoryFactory: RepositoryFactory<any OrderRepository>
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let sessionDataSourceFactory: DataSourceFactory<CheckoutSessionModel>
    let sessionMapper: CheckoutSessionMapper
    let lockDataSourceFactory: DataSourceFactory<CheckoutLockModel>
    /// Handle for the non-transactional scan of pending sessions (queries cannot run
    /// inside a transaction with the pinned FirebaseAPI, roadmap §7 S05).
    let directTransaction: @Sendable () -> any Sendable
    let logger: Logger

    /// Returns the invoice id.
    func execute(params: Params) async throws -> String {
        logger.info("Executing PurchaseSubscriptionUseCase", metadata: [
            "accountId": .string(params.accountId)
        ])

        // Fail closed without an authenticated actor.
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

        // Policy Enforcement Point (bug 9: Node never checked membership).
        let membership = AccountMembership(account: account, hasPermissionDocument: permission != nil)
        switch ability.evaluate(principal: principal, subject: membership) {
        case .allowed:
            break
        case .denied(let reason):
            logger.notice("PurchaseSubscriptionUseCase denied", metadata: [
                "accountId": .string(account.id),
                "principal": .string(principal.id),
                "reason": .string(reason)
            ])
            throw AuthorizationError.denied(reason: reason)
        }

        let payload = params.payload
        guard let planId = payload.planId, !planId.isEmpty else {
            throw PurchaseSubscriptionCommand.Error.planIdRequired
        }
        let requested = try payload.requestedPrice()

        guard let plan = try await planRepositoryFactory(context).fetch(byId: Plan.Id(rawValue: planId)) else {
            throw ApplicationError.notFound(entity: "Plan", id: Plan.Id(rawValue: planId))
        }
        guard plan.isActive else { throw PlanNotActiveError(planId: planId) }
        // D9: duration + currency name + amount. The order is written with the plan's own
        // matching price (it carries symbol/base/digits, which Flutter omits).
        guard plan.matches(price: requested), let planPrice = plan.price(matching: requested) else {
            throw PlanPriceMismatchError(planId: planId)
        }

        let customer = try await resolveCustomer(principal: principal, fallbackEmail: params.customerEmail)

        let lock = try await ensureNoPendingCheckout(accountId: account.id)

        // MARK: Writes

        let order = try Order.create(
            accountId: account.id,
            customerId: User.Id(rawValue: principal.id),
            lineItems: [try PlanOrderProduct.from(plan: plan, price: planPrice)],
            shipment: ShipmentInfo(method: .electronic, address: customer.email),
            customer: customer
        )
        let invoice = try order.createInvoice()

        try await invoiceRepositoryFactory(context).insert(entity: invoice)
        try await orderRepositoryFactory(context).insert(entity: order)

        try await sessionDataSourceFactory("accounts/\(account.id)", context.transaction).insert(
            model: sessionMapper.toModel(entity: CheckoutSession(
                invoiceId: invoice.id,
                accountId: account.id,
                orderId: order.id,
                status: .pending,
                paymentPageURL: nil,
                transactionId: nil,
                error: nil
            ))
        )

        let lockModel = CheckoutLockModel(
            accountId: account.id,
            invoiceId: invoice.id.rawValue,
            createdAt: Timestamp(exact: invoice.createdAt)
        )
        let lockSource = lockDataSourceFactory("", context.transaction)
        if lock != nil {
            try await lockSource.update(model: lockModel)
        } else {
            try await lockSource.insert(model: lockModel)
        }

        return invoice.id.rawValue
    }

    // MARK: Customer

    /// Node: `users/{uid}` or "Customer not found". The `users/{uid}` document is written
    /// asynchronously by the onboarding webhook (and S08 may leave a bare profile first),
    /// so a missing document or email falls back to the token's email; only when there is
    /// neither is the customer unknown (404).
    private func resolveCustomer(principal: any Principal, fallbackEmail: String?) async throws -> CustomerInfo {
        let user = try await userRepositoryFactory(context).fetch(byId: User.Id(rawValue: principal.id))
        let email = [user?.email, fallbackEmail].compactMap { $0 }.first { !$0.isEmpty }
        if user == nil && email == nil {
            throw CustomerNotFoundError(userId: principal.id)
        }
        let name = user?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Anonymous"
        return CustomerInfo(name: name, email: email, phone: nil, address: nil)
    }

    // MARK: One pending checkout per account

    /// Throws ``PendingCheckoutSessionError`` (409) if the account has a `pending` session.
    /// Returns the existing lock document (stale, to be overwritten) if there is one.
    ///
    /// 1. direct query for any `pending` session: catches sessions with no lock (written
    ///    by the LiqPay extension, or seeded directly);
    /// 2. the lock's transactional `get`: the concurrency backstop (see ``CheckoutLockModel``).
    private func ensureNoPendingCheckout(accountId: String) async throws -> CheckoutLockModel? {
        let prefix = "accounts/\(accountId)"
        let pending = try await sessionDataSourceFactory(prefix, directTransaction()).query(
            DataSourceQuery(
                filters: [DataSourceFilter(field: "status", op: .equal, value: CheckoutSessionStatus.pending.rawValue)],
                limit: 1
            )
        )
        if !pending.items.isEmpty {
            throw PendingCheckoutSessionError(accountId: accountId)
        }

        guard let lock = try await lockDataSourceFactory("", context.transaction).fetch(byId: accountId) else {
            return nil
        }
        let session = try await sessionDataSourceFactory(prefix, context.transaction).fetch(byId: lock.invoiceId)
        if session?.status == .pending {
            throw PendingCheckoutSessionError(accountId: accountId)
        }
        return lock
    }
}

extension Plan {

    /// The plan's own price that D9 matches `requested` against (duration + currency name + amount).
    func price(matching requested: PlanPrice) -> PlanPrice? {
        prices.first {
            $0.duration == requested.duration
                && $0.price.currency.name == requested.price.currency.name
                && $0.price.amount == requested.price.amount
        }
    }
}
