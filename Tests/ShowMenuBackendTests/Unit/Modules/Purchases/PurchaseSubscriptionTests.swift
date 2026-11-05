import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

/// `POST /accounts/:accountId/purchases`: membership PEP, plan/price rules, the pending
/// checkout guard, the single transaction, the post-commit gateway step and idempotent replay.
@Suite("Purchase subscription")
struct PurchaseSubscriptionTests {

    // MARK: Doubles

    private actor InMemoryPermissionStore: AccountPermissionStore {
        private var docs: [String: AccountPermissionModel] = [:]

        func put(_ permission: AccountPermissionModel, accountId: String, userId: String) async throws {
            docs["\(accountId)/\(userId)"] = permission
        }

        func fetch(accountId: String, userId: String) async throws -> AccountPermissionModel? {
            docs["\(accountId)/\(userId)"]
        }
    }

    private actor StubGateway: PaymentGateway {
        nonisolated let isSandbox = true
        private var outcome: Result<URL, PaymentGatewayError> = .success(URL(string: "https://pay.example/checkout")!)
        private(set) var requests: [CheckoutRequest] = []

        func failWith(_ error: PaymentGatewayError) { outcome = .failure(error) }

        func checkout(_ request: CheckoutRequest) async throws -> URL {
            requests.append(request)
            return try outcome.get()
        }

        func status(orderId: String) async throws -> PaymentStatus { throw PaymentGatewayError.notConfigured }

        nonisolated func decodeCallback(data: String, signature: String) throws -> PaymentStatus {
            throw PaymentGatewayError.notConfigured
        }
    }

    /// A unit of work whose every `execute` fails, standing in for a store outage while the
    /// checkout failure is being recorded.
    private struct FailingUnitOfWork: UnitOfWork {
        struct Outage: Error, Equatable {}
        let dispatcher: any DomainEventDispatcher = SpyDomainEventDispatcher()

        func execute<Result: Sendable>(
            _ work: @escaping @Sendable (StubUnitOfWorkContext) async throws -> Result
        ) async throws -> Result {
            throw Outage()
        }
    }

    private struct SUT {
        let accounts: InMemoryDataSource<AccountModel>
        let permissions: InMemoryPermissionStore
        let plans: InMemoryDataSource<PlanModel>
        let users: InMemoryDataSource<UserModel>
        let orders: InMemoryDataSource<OrderModel>
        let invoices: InMemoryDataSource<InvoiceModel>
        let sessions: InMemoryDataSource<CheckoutSessionModel>
        let locks: InMemoryDataSource<CheckoutLockModel>
        let idempotency: InMemoryIdempotencyStore
        let gateway: StubGateway
        let uow: StubUnitOfWork
        let flow: PurchaseSubscriptionFlow
        let planId: String
    }

    private let accountId = "account-1"
    private let creator = "uid-creator"

    private func makeSUT(planActive: Bool = true, blindScan: Bool = false, failRecording: Bool = false) async throws -> SUT {
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        let accounts = InMemoryDataSource<AccountModel>(id: { $0.id })
        let permissions = InMemoryPermissionStore()
        let plans = InMemoryDataSource<PlanModel>(id: { $0.id })
        let users = InMemoryDataSource<UserModel>(id: { $0.id })
        let orders = InMemoryDataSource<OrderModel>(id: { $0.id })
        let invoices = InMemoryDataSource<InvoiceModel>(id: { $0.id })
        let sessions = InMemoryDataSource<CheckoutSessionModel>(
            id: { $0.invoiceId },
            matchesFilter: { model, filter in
                filter.field == "status" ? (filter.value as? String) == model.status.rawValue : true
            }
        )
        let locks = InMemoryDataSource<CheckoutLockModel>(id: { $0.accountId })
        let idempotency = InMemoryIdempotencyStore()
        let gateway = StubGateway()
        let uow = StubUnitOfWork()
        // `blindScan` makes the direct pending-session query see nothing, as a concurrent
        // uncommitted write would be invisible to it (isolates the lock backstop).
        let blind = InMemoryDataSource<CheckoutSessionModel>(id: { $0.invoiceId })

        await accounts.seed(AccountModel(id: accountId, name: "Cafe", creator: creator))
        let plan = try Plan.create(
            SKU: "SKU-1",
            name: LocalizedString(["en": "Pro"]),
            description: LocalizedString(["en": "Desc"]),
            isActive: planActive,
            prices: [PlanPrice(
                price: try Price(currency: Currency(name: "USD", symbol: "$", base: 100, digits: 2), amount: 100),
                duration: .monthly
            )],
            features: [PlanFeature(featureId: .init(rawValue: "feature-1"), quota: FeatureQuota(unit: .count, limit: 5))]
        )
        await plans.seed(PlanMapper().toModel(entity: plan))

        let planMapper = PlanMapper(), userMapper = UserMapper(), orderMapper = OrderMapper(), invoiceMapper = InvoiceMapper()
        let sessionMapper = CheckoutSessionMapper()
        let useCase: UseCaseFactory<PurchaseSubscriptionUseCase> = { ctx in
            PurchaseSubscriptionUseCase(
                context: ctx,
                accountDataSourceFactory: { _, _ in accounts },
                accountMapper: AccountMapper(),
                permissionStoreFactory: { _ in permissions },
                ability: AccountMemberAbility(),
                planRepositoryFactory: { ctx in
                    FirestorePlanRepository(
                        mapper: planMapper, dataSourceFactory: { _, _ in plans },
                        skuDataSourceFactory: { _, _ in InMemoryDataSource<PlanSKUModel>(id: { $0.id }) }, context: ctx
                    )
                },
                userRepositoryFactory: { ctx in
                    FirestoreUserRepository(mapper: userMapper, dataSourceFactory: { _, _ in users }, context: ctx)
                },
                orderRepositoryFactory: { ctx in
                    FirestoreOrderRepository(mapper: orderMapper, dataSourceFactory: { _, _ in orders }, context: ctx)
                },
                invoiceRepositoryFactory: { ctx in
                    FirestoreInvoiceRepository(mapper: invoiceMapper, dataSourceFactory: { _, _ in invoices }, context: ctx)
                },
                sessionDataSourceFactory: { _, tx in blindScan && (tx as? String) == "direct" ? blind : sessions },
                sessionMapper: sessionMapper,
                lockDataSourceFactory: { _, _ in locks },
                directTransaction: { "direct" },
                logger: logger
            )
        }
        let handler = PurchaseSubscriptionCommandHandler(
            unitOfWork: uow,
            useCaseFactory: useCase,
            idempotency: IdempotencyComponents(storeFactory: { _ in idempotency }),
            logger: logger
        )
        let initiator = CheckoutInitiator(
            // The purchase itself commits through `uow`; only the post-commit recording fails.
            unitOfWork: failRecording ? FailingUnitOfWork() : uow,
            gateway: gateway,
            sessionDataSourceFactory: { _, _ in sessions },
            sessionMapper: sessionMapper,
            invoiceDataSourceFactory: { _, _ in invoices },
            invoiceMapper: invoiceMapper,
            invoiceRepositoryFactory: { ctx in
                FirestoreInvoiceRepository(mapper: invoiceMapper, dataSourceFactory: { _, _ in invoices }, context: ctx)
            },
            orderRepositoryFactory: { ctx in
                FirestoreOrderRepository(mapper: orderMapper, dataSourceFactory: { _, _ in orders }, context: ctx)
            },
            directTransaction: { "direct" },
            logger: logger
        )
        return SUT(
            accounts: accounts, permissions: permissions, plans: plans, users: users, orders: orders,
            invoices: invoices, sessions: sessions, locks: locks, idempotency: idempotency, gateway: gateway,
            uow: uow, flow: PurchaseSubscriptionFlow(purchase: handler, checkout: initiator), planId: plan.id.rawValue
        )
    }

    private func command(
        _ sut: SUT, account: String? = nil, planId: String? = nil, amount: Double? = 100, duration: String? = "monthly",
        symbol: String? = "$", base: Int? = 100, email: String? = nil
    ) -> PurchaseSubscriptionCommand {
        PurchaseSubscriptionCommand(
            accountId: account ?? accountId,
            customerEmail: email,
            payload: .init(
                planId: planId ?? sut.planId,
                price: .init(
                    price: .init(
                        currencyName: "USD", currencySymbol: symbol, currencyBase: base, currencyDigits: nil, amount: amount
                    ),
                    duration: duration
                )
            ),
            metadata: CommandMetadata(correlationId: "test")
        )
    }

    private func run(
        _ sut: SUT, as principal: any Principal, key: String? = nil, _ command: PurchaseSubscriptionCommand
    ) async throws -> String {
        try await RequestContext.$principal.withValue(principal) {
            if let key {
                return try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey(key)) {
                    try await sut.flow.run(command)
                }
            }
            return try await sut.flow.run(command)
        }
    }

    private var owner: StubPrincipal { StubPrincipal(id: creator) }

    // MARK: Happy path

    @Test("happy path: order + invoice + pending session + lock in one go, then the payment page")
    func happyPath() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "max@example.com", name: "Max"))

        let invoiceId = try await run(sut, as: owner, command(sut))

        #expect(invoiceId.hasPrefix("invoice-"))
        let invoice = try #require(await sut.invoices.insertedModels.first)
        #expect(invoice.id == invoiceId)
        #expect(invoice.status == .pending)
        let order = try #require(await sut.orders.insertedModels.first)
        #expect(order.id == invoice.orderId)
        #expect(order.status == .created)
        #expect(order.accountId == accountId)
        #expect(order.invoiceId == invoiceId)
        #expect(order.customer.name == "Max")
        #expect(order.customer.email == "max@example.com")
        #expect(order.shipment.address == "max@example.com")
        let line = try #require(order.lineItems.first)
        #expect(line.duration == .monthly)
        #expect(line.productPrice.amount == 100)
        // The order carries the plan's own price (symbol/base/digits included).
        #expect(line.productPrice.currency.digits == 2)

        let session = try #require(try await sut.sessions.fetch(byId: invoiceId))
        #expect(session.status == .pending)
        #expect(session.orderId == order.id)
        #expect(session.paymentPageURL == "https://pay.example/checkout")
        #expect(await sut.sessions.updatedModels.count == 1)
        #expect(try await sut.locks.fetch(byId: accountId)?.invoiceId == invoiceId)

        let requests = await sut.gateway.requests
        #expect(requests.count == 1)
        #expect(requests.first?.orderId == invoiceId)
        #expect(requests.first?.amount == 100)
        #expect(requests.first?.currency == "USD")
        #expect(requests.first?.subscription == .monthly)
    }

    // MARK: Authorization (bug 9)

    @Test("a stranger is denied and nothing is written")
    func stranger() async throws {
        let sut = try await makeSUT()
        await #expect(throws: AuthorizationError.self) {
            _ = try await run(sut, as: StubPrincipal(id: "uid-stranger"), command(sut))
        }
        #expect(await sut.orders.insertedModels.isEmpty)
        #expect(await sut.invoices.insertedModels.isEmpty)
        #expect(await sut.sessions.insertedModels.isEmpty)
        #expect(await sut.gateway.requests.isEmpty)
    }

    @Test("a user with a permission document may purchase")
    func permissionHolder() async throws {
        let sut = try await makeSUT()
        try await sut.permissions.put(
            AccountPermissionModel(role: "owner", permissions: []), accountId: accountId, userId: "uid-member"
        )
        await sut.users.seed(UserModel(id: "uid-member", email: "m@example.com", name: "Member"))
        let invoiceId = try await run(sut, as: StubPrincipal(id: "uid-member"), command(sut))
        let order = try #require(await sut.orders.insertedModels.first)
        #expect(order.customerId == "uid-member")
        #expect(invoiceId.hasPrefix("invoice-"))
    }

    @Test("an admin may purchase on any account")
    func admin() async throws {
        let sut = try await makeSUT()
        let invoiceId = try await run(
            sut, as: StubPrincipal(id: "uid-admin", roles: [.admin]), command(sut, email: "admin@example.com")
        )
        #expect(invoiceId.hasPrefix("invoice-"))
    }

    @Test("no principal fails closed")
    func noPrincipal() async throws {
        let sut = try await makeSUT()
        await #expect(throws: AuthorizationError.missingPrincipal) {
            _ = try await sut.flow.run(command(sut, email: "x@example.com"))
        }
    }

    @Test("AccountMemberAbility: creator, permission holder, admin allowed; others denied")
    func ability() throws {
        let account = Account(id: "a", name: nil, creator: "c")
        let ability = AccountMemberAbility()
        func decide(_ principal: StubPrincipal, permission: Bool) -> Decision {
            ability.evaluate(principal: principal, subject: AccountMembership(account: account, hasPermissionDocument: permission))
        }
        #expect(decide(StubPrincipal(id: "c"), permission: false) == .allowed)
        #expect(decide(StubPrincipal(id: "m"), permission: true) == .allowed)
        #expect(decide(StubPrincipal(id: "x", roles: [.admin]), permission: false) == .allowed)
        if case .denied = decide(StubPrincipal(id: "x"), permission: false) {} else { Issue.record("expected denied") }
    }

    // MARK: Not found / validation

    @Test("unknown account -> AccountNotFoundError (404)")
    func accountNotFound() async throws {
        let sut = try await makeSUT()
        await #expect(throws: AccountNotFoundError.self) {
            _ = try await run(sut, as: owner, command(sut, account: "missing"))
        }
    }

    @Test("unknown plan -> notFound (404)")
    func planNotFound() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        do {
            _ = try await run(sut, as: owner, command(sut, planId: "plan-missing"))
            Issue.record("expected notFound")
        } catch ApplicationError.notFound(entity: "Plan", id: _) {
        }
    }

    @Test("inactive plan -> 422")
    func inactivePlan() async throws {
        let sut = try await makeSUT(planActive: false)
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await #expect(throws: PlanNotActiveError.self) {
            _ = try await run(sut, as: owner, command(sut))
        }
    }

    @Test("price mismatch (amount / duration) -> 422")
    func priceMismatch() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await #expect(throws: PlanPriceMismatchError.self) {
            _ = try await run(sut, as: owner, command(sut, amount: 99))
        }
        await #expect(throws: PlanPriceMismatchError.self) {
            _ = try await run(sut, as: owner, command(sut, duration: "yearly"))
        }
        #expect(await sut.orders.insertedModels.isEmpty)
    }

    @Test("D9: symbol / base / digits are ignored when matching the price")
    func priceMatchIgnoresCurrencyDetails() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        let invoiceId = try await run(sut, as: owner, command(sut, symbol: nil, base: nil))
        #expect(invoiceId.hasPrefix("invoice-"))
    }

    @Test("validation: missing planId, price, amount, bad duration -> 422 errors")
    func validation() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        func payload(_ planId: String?, _ price: PurchaseSubscriptionCommand.PlanPriceInput?) -> PurchaseSubscriptionCommand {
            PurchaseSubscriptionCommand(
                accountId: accountId, customerEmail: nil, payload: .init(planId: planId, price: price),
                metadata: CommandMetadata(correlationId: "test")
            )
        }
        await #expect(throws: PurchaseSubscriptionCommand.Error.planIdRequired) {
            _ = try await run(sut, as: owner, payload(nil, nil))
        }
        await #expect(throws: PurchaseSubscriptionCommand.Error.priceRequired) {
            _ = try await run(sut, as: owner, payload(sut.planId, nil))
        }
        await #expect(throws: PurchaseSubscriptionCommand.Error.amountRequired) {
            _ = try await run(sut, as: owner, payload(sut.planId, .init(
                price: .init(currencyName: "USD", currencySymbol: nil, currencyBase: nil, currencyDigits: nil, amount: nil),
                duration: "monthly"
            )))
        }
        await #expect(throws: Plan.Error.self) {
            _ = try await run(sut, as: owner, command(sut, duration: "fortnightly"))
        }
        #expect(await sut.orders.insertedModels.isEmpty)
    }

    // MARK: Customer

    @Test("no users/{uid} document: falls back to the token email and 'Anonymous'")
    func customerFallback() async throws {
        let sut = try await makeSUT()
        _ = try await run(sut, as: owner, command(sut, email: "token@example.com"))
        let order = try #require(await sut.orders.insertedModels.first)
        #expect(order.customer.name == "Anonymous")
        #expect(order.customer.email == "token@example.com")
        #expect(order.shipment.address == "token@example.com")
    }

    @Test("a bare profile (no email) also falls back to the token email")
    func bareProfile() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator))
        _ = try await run(sut, as: owner, command(sut, email: "token@example.com"))
        #expect(try #require(await sut.orders.insertedModels.first).customer.email == "token@example.com")
    }

    @Test("neither a user document nor a token email -> CustomerNotFoundError (404)")
    func customerNotFound() async throws {
        let sut = try await makeSUT()
        await #expect(throws: CustomerNotFoundError.self) {
            _ = try await run(sut, as: owner, command(sut))
        }
        #expect(await sut.orders.insertedModels.isEmpty)
    }

    // MARK: Pending checkout guard

    @Test("a pending session written elsewhere (extension / seed, no lock) -> 409")
    func pendingSeeded() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.sessions.seed(CheckoutSessionModel(status: .pending, invoiceId: "invoice-old", paymentPageURL: "https://x"))
        await #expect(throws: PendingCheckoutSessionError.self) {
            _ = try await run(sut, as: owner, command(sut))
        }
        #expect(await sut.orders.insertedModels.isEmpty)
        #expect(await sut.gateway.requests.isEmpty)
    }

    @Test("a second purchase right after the first -> 409 (session is pending)")
    func secondPurchase() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        _ = try await run(sut, as: owner, command(sut))
        await #expect(throws: PendingCheckoutSessionError.self) {
            _ = try await run(sut, as: owner, command(sut))
        }
        #expect(await sut.orders.insertedModels.count == 1)
    }

    @Test("the lock is the backstop: it names a pending session the scan could not see")
    func lockBackstop() async throws {
        let sut = try await makeSUT(blindScan: true)
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.sessions.seed(CheckoutSessionModel(status: .pending, invoiceId: "invoice-racing"))
        await sut.locks.seed(CheckoutLockModel(accountId: accountId, invoiceId: "invoice-racing", createdAt: Timestamp(exact: .now)))
        await #expect(throws: PendingCheckoutSessionError.self) {
            _ = try await run(sut, as: owner, command(sut))
        }
    }

    @Test("a stale lock (its session is terminal) is overwritten, not a 409; nothing had to release it")
    func staleLock() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.sessions.seed(CheckoutSessionModel(status: .cancelled, invoiceId: "invoice-old"))
        await sut.locks.seed(CheckoutLockModel(accountId: accountId, invoiceId: "invoice-old", createdAt: Timestamp(exact: .now)))
        let invoiceId = try await run(sut, as: owner, command(sut))
        #expect(try await sut.locks.fetch(byId: accountId)?.invoiceId == invoiceId)
        #expect(await sut.locks.updatedModels.count == 1)
        #expect(await sut.locks.insertedModels.count == 0)
    }

    // MARK: Gateway failure (bug 4)

    @Test("gateway failure: session failure + error fields, order and invoice failed, error rethrown")
    func gatewayFailure() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.gateway.failWith(.transport("boom"))

        await #expect(throws: PaymentGatewayError.transport("boom")) {
            _ = try await run(sut, as: owner, command(sut))
        }

        let invoice = try #require(await sut.invoices.insertedModels.first)
        let session = try #require(try await sut.sessions.fetch(byId: invoice.id))
        #expect(session.status == .failure)
        #expect(session.errorCode == CheckoutInitiator.failureCode)
        #expect(session.errorMessage != nil)
        #expect(session.paymentPageURL == nil)
        #expect(try await sut.orders.fetch(byId: invoice.orderId)?.status == .failed)
        #expect(try await sut.invoices.fetch(byId: invoice.id)?.status == .failed)

        // The failed session no longer blocks the account.
        await sut.gateway.failWith(.transport("boom"))
        let retry = try? await run(sut, as: owner, command(sut))
        #expect(retry == nil)  // gateway still failing, but it got past the 409 guard:
        #expect(await sut.orders.insertedModels.count == 2)
    }

    @Test("recording the failure fails too: the gateway error is still the one surfaced")
    func gatewayFailureRecordingFails() async throws {
        let sut = try await makeSUT(failRecording: true)
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.gateway.failWith(.transport("boom"))

        // Not `Outage`: the client must see the gateway's hint (502/503), not a storage error.
        await #expect(throws: PaymentGatewayError.transport("boom")) {
            _ = try await run(sut, as: owner, command(sut))
        }

        // Nothing could be recorded: the purchase stays as committed, session still pending.
        let invoice = try #require(await sut.invoices.insertedModels.first)
        #expect(try await sut.sessions.fetch(byId: invoice.id)?.status == .pending)
        #expect(try await sut.invoices.fetch(byId: invoice.id)?.status == .pending)
    }

    // MARK: Idempotency

    @Test("same Idempotency-Key: replays the invoice id, one order, one checkout")
    func replay() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))

        let first = try await run(sut, as: owner, key: "key-1", command(sut))
        let second = try await run(sut, as: owner, key: "key-1", command(sut))

        #expect(first == second)
        #expect(await sut.orders.insertedModels.count == 1)
        #expect(await sut.invoices.insertedModels.count == 1)
        #expect(await sut.gateway.requests.count == 1)
    }

    @Test("the same key against another account is rejected, not replayed")
    func replayOtherAccount() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        await sut.accounts.seed(AccountModel(id: "account-2", name: "Other", creator: creator))
        _ = try await run(sut, as: owner, key: "key-1", command(sut))
        await #expect(throws: IdempotencyError.fingerprintMismatch(key: "key-1")) {
            _ = try await run(sut, as: owner, key: "key-1", command(sut, account: "account-2"))
        }
    }

    @Test("a replay finishes a checkout that never ran (crash between commit and gateway call)")
    func replayHealsCrash() async throws {
        let sut = try await makeSUT()
        await sut.users.seed(UserModel(id: creator, email: "a@b.c", name: "A"))
        // First attempt: purchase committed, then the process died before the gateway step.
        let invoiceId = try await RequestContext.$principal.withValue(owner) {
            try await RequestContext.$idempotencyKey.withValue(try IdempotencyKey("key-1")) {
                try await sut.flow.purchase.handle(command(sut))
            }
        }
        #expect(try await sut.sessions.fetch(byId: invoiceId)?.paymentPageURL == nil)

        let replayed = try await run(sut, as: owner, key: "key-1", command(sut))

        #expect(replayed == invoiceId)
        #expect(try await sut.sessions.fetch(byId: invoiceId)?.paymentPageURL == "https://pay.example/checkout")
        #expect(await sut.orders.insertedModels.count == 1)
    }
}
