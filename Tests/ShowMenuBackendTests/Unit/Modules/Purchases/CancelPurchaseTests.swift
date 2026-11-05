import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// `DELETE /accounts/:accountId/purchases/:invoiceId`: membership PEP, ownership of the
/// invoice, the order loaded through `invoice.orderId`, the three cancellations in one
/// unit of work, repeat cancel and the non-pending statuses.
@Suite("Cancel purchase")
struct CancelPurchaseTests {

    private actor InMemoryPermissionStore: AccountPermissionStore {
        private var docs: [String: AccountPermissionModel] = [:]

        func put(_ permission: AccountPermissionModel, accountId: String, userId: String) async throws {
            docs["\(accountId)/\(userId)"] = permission
        }

        func fetch(accountId: String, userId: String) async throws -> AccountPermissionModel? {
            docs["\(accountId)/\(userId)"]
        }
    }

    private struct SUT {
        let accounts: InMemoryDataSource<AccountModel>
        let permissions: InMemoryPermissionStore
        let orders: InMemoryDataSource<OrderModel>
        let invoices: InMemoryDataSource<InvoiceModel>
        let sessions: InMemoryDataSource<CheckoutSessionModel>
        let handler: CancelPurchaseCommandHandler
        let orderId: String
        let invoiceId: String
    }

    private let accountId = PurchaseFixtures.accountId
    private let creator = "uid-creator"

    private func makeSUT(
        withSession: Bool = true, sessionStatus: CheckoutSessionStatus = .pending, withOrder: Bool = true,
        prepare: (Order, Invoice) throws -> Void = { _, _ in }
    ) async throws -> SUT {
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        let accounts = InMemoryDataSource<AccountModel>(id: { $0.id })
        let permissions = InMemoryPermissionStore()
        let orders = InMemoryDataSource<OrderModel>(id: { $0.id })
        let invoices = InMemoryDataSource<InvoiceModel>(id: { $0.id })
        let sessions = InMemoryDataSource<CheckoutSessionModel>(id: { $0.invoiceId })
        let orderMapper = OrderMapper(), invoiceMapper = InvoiceMapper(), sessionMapper = CheckoutSessionMapper()

        await accounts.seed(AccountModel(id: accountId, name: "Cafe", creator: creator))
        let order = try PurchaseFixtures.makeOrder()
        let invoice = try order.createInvoice()
        try prepare(order, invoice)
        if withOrder { await orders.seed(orderMapper.toModel(entity: order)) }
        await invoices.seed(invoiceMapper.toModel(entity: invoice))
        if withSession {
            await sessions.seed(CheckoutSessionModel(
                status: sessionStatus, invoiceId: invoice.id.rawValue, orderId: order.id.rawValue,
                paymentPageURL: "https://pay.example/checkout"
            ))
        }

        let useCase: UseCaseFactory<CancelPurchaseUseCase> = { ctx in
            CancelPurchaseUseCase(
                context: ctx,
                accountDataSourceFactory: { _, _ in accounts },
                accountMapper: AccountMapper(),
                permissionStoreFactory: { _ in permissions },
                ability: AccountMemberAbility(),
                orderRepositoryFactory: { ctx in
                    FirestoreOrderRepository(mapper: orderMapper, dataSourceFactory: { _, _ in orders }, context: ctx)
                },
                invoiceRepositoryFactory: { ctx in
                    FirestoreInvoiceRepository(mapper: invoiceMapper, dataSourceFactory: { _, _ in invoices }, context: ctx)
                },
                sessionDataSourceFactory: { _, _ in sessions },
                sessionMapper: sessionMapper,
                logger: logger
            )
        }
        let handler = CancelPurchaseCommandHandler(unitOfWork: StubUnitOfWork(), useCaseFactory: useCase, logger: logger)
        return SUT(
            accounts: accounts, permissions: permissions, orders: orders, invoices: invoices, sessions: sessions,
            handler: handler, orderId: order.id.rawValue, invoiceId: invoice.id.rawValue
        )
    }

    private func cancel(
        _ sut: SUT, as principal: (any Principal)? = nil, account: String? = nil, invoice: String? = nil
    ) async throws {
        let command = CancelPurchaseCommand(
            accountId: account ?? accountId, invoiceId: invoice ?? sut.invoiceId,
            metadata: CommandMetadata(correlationId: "test")
        )
        let actor: any Principal = principal ?? StubPrincipal(id: creator)
        try await RequestContext.$principal.withValue(actor) {
            try await sut.handler.handle(command)
        }
    }

    // MARK: Happy path

    @Test("happy path: order via invoice.orderId, invoice and session all cancelled")
    func happyPath() async throws {
        let sut = try await makeSUT()
        try await cancel(sut)

        #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .cancelled)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .cancelled)
        let session = try #require(try await sut.sessions.fetch(byId: sut.invoiceId))
        #expect(session.status == .cancelled)
        // The 7-field shape is preserved (+ orderId).
        #expect(session.paymentPageURL == "https://pay.example/checkout")
        #expect(session.orderId == sut.orderId)
    }

    @Test("a permission holder and an admin may cancel")
    func otherMembers() async throws {
        let holder = try await makeSUT()
        try await holder.permissions.put(AccountPermissionModel(role: "owner", permissions: []), accountId: accountId, userId: "uid-holder")
        try await cancel(holder, as: StubPrincipal(id: "uid-holder"))
        #expect(try await holder.invoices.fetch(byId: holder.invoiceId)?.status == .cancelled)

        let admin = try await makeSUT()
        try await cancel(admin, as: StubPrincipal(id: "uid-admin", roles: [.admin]))
        #expect(try await admin.orders.fetch(byId: admin.orderId)?.status == .cancelled)
    }

    // MARK: Authorization and lookups

    @Test("a stranger gets 403 and nothing changes")
    func stranger() async throws {
        let sut = try await makeSUT()
        await #expect(throws: AuthorizationError.self) {
            try await cancel(sut, as: StubPrincipal(id: "uid-stranger"))
        }
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .pending)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .pending)
    }

    @Test("no principal fails closed")
    func noPrincipal() async throws {
        let sut = try await makeSUT()
        let command = CancelPurchaseCommand(
            accountId: accountId, invoiceId: sut.invoiceId, metadata: CommandMetadata(correlationId: "test")
        )
        await #expect(throws: AuthorizationError.self) { try await sut.handler.handle(command) }
    }

    @Test("unknown account is 404")
    func unknownAccount() async throws {
        let sut = try await makeSUT()
        await #expect(throws: AccountNotFoundError.self) { try await cancel(sut, account: "account-nope") }
    }

    @Test("unknown invoice is 404")
    func unknownInvoice() async throws {
        let sut = try await makeSUT()
        await #expect(throws: ApplicationError.self) { try await cancel(sut, invoice: "invoice-nope") }
    }

    @Test("an invoice of another account is 404 and untouched")
    func foreignInvoice() async throws {
        let sut = try await makeSUT()
        await sut.accounts.seed(AccountModel(id: "account-2", name: "Other", creator: creator))
        await #expect(throws: ApplicationError.self) { try await cancel(sut, account: "account-2") }
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .pending)
        #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .created)
    }

    @Test("missing order is 404 and nothing is cancelled")
    func missingOrder() async throws {
        let sut = try await makeSUT(withOrder: false)
        await #expect(throws: ApplicationError.self) { try await cancel(sut) }
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .pending)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .pending)
    }

    // MARK: Statuses

    @Test("repeat cancel is an idempotent no-op")
    func repeatCancel() async throws {
        let sut = try await makeSUT()
        try await cancel(sut)
        try await cancel(sut)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .cancelled)
        #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .cancelled)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .cancelled)
    }

    @Test("paid, failed and refunded invoices are 409 and untouched")
    func nonPendingInvoice() async throws {
        let setups: [(InvoiceStatus, (Order, Invoice) throws -> Void)] = [
            (.paid, { _, invoice in try invoice.pay() }),
            (.failed, { _, invoice in try invoice.fail() }),
            (.refunded, { _, invoice in try invoice.pay(); try invoice.refund() }),
        ]
        for (status, prepare) in setups {
            let sut = try await makeSUT(prepare: prepare)
            await #expect(throws: InvalidStatusTransitionError.self) { try await cancel(sut) }
            #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == status)
            #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .created)
            #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .pending)
        }
    }

    @Test("a completed order cannot be cancelled (409)")
    func completedOrder() async throws {
        let sut = try await makeSUT(prepare: { order, invoice in try order.complete(invoiceId: invoice.id) })
        await #expect(throws: InvalidStatusTransitionError.self) { try await cancel(sut) }
        #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .completed)
    }

    // MARK: Session

    @Test("missing session: skipped, not created, the rest is cancelled")
    func missingSession() async throws {
        let sut = try await makeSUT(withSession: false)
        try await cancel(sut)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId) == nil)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .cancelled)
        #expect(try await sut.orders.fetch(byId: sut.orderId)?.status == .cancelled)
    }

    @Test("a failed session (checkout failure) becomes cancelled too")
    func failedSession() async throws {
        let sut = try await makeSUT(sessionStatus: .failure)
        try await cancel(sut)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .cancelled)
    }
}
