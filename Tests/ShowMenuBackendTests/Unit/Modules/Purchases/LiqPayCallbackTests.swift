import Foundation
import Testing
import Logging
import Vapor
import VaporTesting
import FirestoreAPI
@testable import ShowMenuBackend

/// `POST /api/v1/payments/liqpay/callback`: edge (signature, malformed), inbox de-duplication,
/// and what each LiqPay status does to the invoice, order, session and audit trail.
@Suite("LiqPay callback")
struct LiqPayCallbackTests {

    private actor InMemoryAuditStore: InvoiceStatusAuditStore {
        private(set) var rows: [(invoiceId: String, rawPayload: String)] = []
        func append(invoiceId: String, rawPayload: String) async throws {
            rows.append((invoiceId, rawPayload))
        }
    }

    private struct SUT {
        let orders: InMemoryDataSource<OrderModel>
        let invoices: InMemoryDataSource<InvoiceModel>
        let sessions: InMemoryDataSource<CheckoutSessionModel>
        let audit: InMemoryAuditStore
        let inbox: StubInboxStore
        let uow: StubUnitOfWork
        let handler: HandleLiqPayCallbackCommandHandler
        let orderId: String
        let invoiceId: String
    }

    private func makeSUT(
        withSession: Bool = true, sessionStatus: CheckoutSessionStatus = .pending, withOrder: Bool = true,
        prepare: (Order, Invoice) throws -> Void = { _, _ in }
    ) async throws -> SUT {
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        let orders = InMemoryDataSource<OrderModel>(id: { $0.id })
        let invoices = InMemoryDataSource<InvoiceModel>(id: { $0.id })
        let sessions = InMemoryDataSource<CheckoutSessionModel>(id: { $0.invoiceId })
        let audit = InMemoryAuditStore()
        let inbox = StubInboxStore()
        let orderMapper = OrderMapper(), invoiceMapper = InvoiceMapper(), sessionMapper = CheckoutSessionMapper()

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

        let useCase: UseCaseFactory<HandleLiqPayCallbackUseCase> = { ctx in
            HandleLiqPayCallbackUseCase(
                context: ctx,
                orderRepositoryFactory: { ctx in
                    FirestoreOrderRepository(mapper: orderMapper, dataSourceFactory: { _, _ in orders }, context: ctx)
                },
                invoiceRepositoryFactory: { ctx in
                    FirestoreInvoiceRepository(mapper: invoiceMapper, dataSourceFactory: { _, _ in invoices }, context: ctx)
                },
                sessionDataSourceFactory: { _, _ in sessions },
                sessionMapper: sessionMapper,
                auditStoreFactory: { _ in audit },
                logger: logger
            )
        }
        let uow = StubUnitOfWork()
        let handler = HandleLiqPayCallbackCommandHandler(
            unitOfWork: uow, useCaseFactory: useCase,
            inbox: InboxComponents(storeFactory: { _ in inbox }), logger: logger
        )
        return SUT(
            orders: orders, invoices: invoices, sessions: sessions, audit: audit, inbox: inbox, uow: uow,
            handler: handler, orderId: order.id.rawValue, invoiceId: invoice.id.rawValue
        )
    }

    // MARK: Helpers

    private func payload(
        _ sut: SUT, status: String, paymentId: String? = "pay-1", transactionId: String? = nil,
        errorCode: String? = nil, errorDescription: String? = nil, info: String? = nil, orderId: String? = nil
    ) -> HandleLiqPayCallbackCommand.Payload {
        .init(
            orderId: orderId ?? sut.invoiceId, status: status, paymentId: paymentId,
            transactionId: transactionId ?? paymentId, errorCode: errorCode, errorDescription: errorDescription,
            info: info, rawPayload: #"{"order_id":"\#(orderId ?? sut.invoiceId)","status":"\#(status)"}"#
        )
    }

    /// Delivers like the controller: the inbox keys on the derived event id.
    private func deliver(_ sut: SUT, _ payload: HandleLiqPayCallbackCommand.Payload) async throws {
        let id = LiqPayCallbackEventId.derive(orderId: payload.orderId, status: payload.status, paymentId: payload.paymentId)
        try await RequestContext.$integrationEventId.withValue(id) {
            try await sut.handler.handle(HandleLiqPayCallbackCommand(
                payload: payload, metadata: CommandMetadata(correlationId: "test")
            ))
        }
    }

    private func eventKinds(_ sut: SUT) -> [String] {
        // Semantic events only (`invoice.*`); the Repository's lifecycle `updated` is not under test.
        sut.uow.dispatchedEvents.compactMap { ($0 as? InvoiceEvent)?.kind.rawValue }.filter { $0.hasPrefix("invoice.") }
    }

    private func state(_ sut: SUT) async throws -> (invoice: InvoiceStatus, order: OrderStatus, session: CheckoutSessionStatus?) {
        (
            try #require(try await sut.invoices.fetch(byId: sut.invoiceId)).status,
            try #require(try await sut.orders.fetch(byId: sut.orderId)).status,
            try await sut.sessions.fetch(byId: sut.invoiceId)?.status
        )
    }

    // MARK: Each LiqPay status

    @Test("success: invoice paid, order completed, session success with the transaction id; invoice.paid dispatched")
    func success() async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: "success", paymentId: "pay-1", transactionId: "tx-1"))

        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == .success)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.transactionId == "tx-1")
        let session = try #require(try await sut.sessions.fetch(byId: sut.invoiceId))
        #expect(session.transactionId == "tx-1")
        #expect(session.errorCode == nil)
        // The 7-field shape is preserved (+ orderId).
        #expect(session.paymentPageURL == "https://pay.example/checkout")
        #expect(session.orderId == sut.orderId)
        #expect(eventKinds(sut).contains("invoice.paid"))
        #expect(await sut.audit.rows.count == 1)
    }

    @Test("status mapping", arguments: [
        // status, invoice, order, session, invoice event
        ("success", InvoiceStatus.paid, OrderStatus.completed, CheckoutSessionStatus.success, "invoice.paid"),
        ("subscribed", .paid, .completed, .success, "invoice.paid"),
        ("failure", .failed, .failed, .failure, "invoice.failed"),
        ("error", .failed, .failed, .failure, "invoice.failed"),
        ("unsubscribed", .cancelled, .cancelled, .cancelled, "invoice.cancelled"),
    ])
    func statusMapping(row: (String, InvoiceStatus, OrderStatus, CheckoutSessionStatus, String)) async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: row.0))
        let s = try await state(sut)
        #expect(s.invoice == row.1 && s.order == row.2 && s.session == row.3)
        #expect(eventKinds(sut).contains(row.4))
    }

    @Test("reversed after a paid invoice: invoice refunded, order refunded, session cancelled")
    func reversed() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay(transactionId: "tx-1")
            try order.complete(invoiceId: invoice.id)
        }
        try await deliver(sut, payload(sut, status: "reversed", paymentId: "pay-2"))
        let s = try await state(sut)
        #expect(s.invoice == .refunded && s.order == .refunded && s.session == .cancelled)
        #expect(eventKinds(sut).contains("invoice.refunded"))
    }

    @Test("in-flight statuses change no aggregate and keep the session pending", arguments: ["processing", "wait_accept", "3ds_verify"])
    func inFlight(status: String) async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: status))
        let s = try await state(sut)
        #expect(s.invoice == .pending && s.order == .created && s.session == .pending)
        #expect(eventKinds(sut).isEmpty)
        #expect(await sut.audit.rows.count == 1)
    }

    @Test("a failure carries the error fields into the session: code, description, info")
    func errorFields() async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(
            sut, status: "failure", errorCode: "cvv", errorDescription: "Bad CVV", info: "details"
        ))
        let session = try #require(try await sut.sessions.fetch(byId: sut.invoiceId))
        #expect(session.status == .failure)
        #expect(session.errorCode == "cvv" && session.errorMessage == "Bad CVV" && session.errorDetails == "details")
    }

    // MARK: Duplicates and unknowns

    @Test("a duplicate callback is a no-op: one audit doc, one event, same state")
    func duplicate() async throws {
        let sut = try await makeSUT()
        let first = payload(sut, status: "success", paymentId: "pay-1")
        try await deliver(sut, first)
        let eventsAfterFirst = eventKinds(sut)
        try await deliver(sut, first)

        #expect(await sut.audit.rows.count == 1)
        #expect(eventKinds(sut) == eventsAfterFirst)
        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == .success)
    }

    @Test("the same status with another payment id is not a duplicate for the inbox")
    func distinctPayment() async throws {
        #expect(
            LiqPayCallbackEventId.derive(orderId: "o", status: "success", paymentId: "1")
                != LiqPayCallbackEventId.derive(orderId: "o", status: "success", paymentId: "2")
        )
        #expect(
            LiqPayCallbackEventId.derive(orderId: "o", status: "success", paymentId: "1")
                == LiqPayCallbackEventId.derive(orderId: "o", status: "success", paymentId: "1")
        )
    }

    @Test("an unknown invoice is acknowledged without writing anything")
    func unknownInvoice() async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: "success", orderId: "invoice-does-not-exist"))
        #expect(await sut.audit.rows.isEmpty)
        let s = try await state(sut)
        #expect(s.invoice == .pending && s.order == .created && s.session == .pending)
        // The inbox marker is still written, so a LiqPay retry is a silent skip.
        #expect(await sut.inbox.count == 1)
    }

    @Test("an order_id that cannot be a document id is treated as unknown")
    func slashOrderId() async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: "success", orderId: "a/b"))
        #expect(await sut.audit.rows.isEmpty)
    }

    // MARK: Invalid transitions never fail the callback

    @Test("a late success after failure: audit written, invoice/order/session untouched, no error")
    func lateSuccessAfterFailure() async throws {
        let sut = try await makeSUT(sessionStatus: .failure) { order, invoice in
            try invoice.fail()
            try order.fail(invoiceId: invoice.id)
        }
        try await deliver(sut, payload(sut, status: "success"))

        let s = try await state(sut)
        #expect(s.invoice == .failed && s.order == .failed && s.session == .failure)
        #expect(await sut.audit.rows.count == 1)
        #expect(!eventKinds(sut).contains("invoice.paid"))
    }

    @Test("unsubscribed on a paid invoice is an invalid edge: acknowledged, nothing changes")
    func unsubscribedOnPaid() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay(transactionId: "tx-1")
            try order.complete(invoiceId: invoice.id)
        }
        try await deliver(sut, payload(sut, status: "unsubscribed"))
        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == .success)
        #expect(await sut.audit.rows.count == 1)
    }

    @Test("an order that cannot follow the invoice keeps both unchanged (all-or-nothing)")
    func orderRejects() async throws {
        // The order was failed by an earlier checkout failure, while the invoice is still pending.
        let sut = try await makeSUT { order, invoice in try order.fail(invoiceId: invoice.id) }
        try await deliver(sut, payload(sut, status: "success"))
        let s = try await state(sut)
        #expect(s.invoice == .pending && s.order == .failed && s.session == .pending)
        #expect(eventKinds(sut).isEmpty)
        #expect(await sut.audit.rows.count == 1)
    }

    @Test("same status again (a paid invoice, success with the same payment): no-op, no event")
    func sameStatus() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay(transactionId: "tx-1")
            try order.complete(invoiceId: invoice.id)
        }
        try await deliver(sut, payload(sut, status: "subscribed", paymentId: "tx-1"))
        #expect(eventKinds(sut).isEmpty)
        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == .success)
    }

    // MARK: Missing documents

    @Test("a missing session is skipped, not created; invoice and order still move")
    func missingSession() async throws {
        let sut = try await makeSUT(withSession: false)
        try await deliver(sut, payload(sut, status: "success"))
        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == nil)
    }

    @Test("a missing order is logged; invoice and session still move")
    func missingOrder() async throws {
        let sut = try await makeSUT(withOrder: false)
        try await deliver(sut, payload(sut, status: "success"))
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.status == .paid)
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .success)
    }

    @Test("a terminal session is never moved back to pending by an in-flight status")
    func noRegression() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay(transactionId: "tx-1")
            try order.complete(invoiceId: invoice.id)
        }
        try await deliver(sut, payload(sut, status: "processing", paymentId: "pay-9"))
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.status == .success)
    }

    // MARK: Renewal signal (S14)

    @Test("a new payment on a paid invoice raises invoice.renewed and stores the new payment identity")
    func renewal() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay(transactionId: "tx-1")
            try order.complete(invoiceId: invoice.id)
            _ = invoice.pullEvents()
        }
        try await deliver(sut, payload(sut, status: "success", paymentId: "pay-2", transactionId: "tx-2"))

        #expect(eventKinds(sut) == ["invoice.renewed"])
        let s = try await state(sut)
        #expect(s.invoice == .paid && s.order == .completed && s.session == .success)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.transactionId == "tx-2")
        #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.transactionId == "tx-2")

        // The same payment redelivered under another status string is not a second renewal.
        try await deliver(sut, payload(sut, status: "subscribed", paymentId: "pay-2", transactionId: "tx-2"))
        #expect(eventKinds(sut) == ["invoice.renewed"])

        // Next period: another one.
        try await deliver(sut, payload(sut, status: "success", paymentId: "pay-3", transactionId: "tx-3"))
        #expect(eventKinds(sut) == ["invoice.renewed", "invoice.renewed"])
    }

    @Test("the first payment of a subscription is a payment, not a renewal")
    func firstPaymentIsNotRenewal() async throws {
        let sut = try await makeSUT()
        try await deliver(sut, payload(sut, status: "subscribed", paymentId: "pay-1", transactionId: "tx-1"))
        #expect(eventKinds(sut) == ["invoice.paid"])
    }

    @Test("a legacy paid invoice without a payment identity adopts it silently")
    func legacyPaidAdoptsIdentity() async throws {
        let sut = try await makeSUT(sessionStatus: .success) { order, invoice in
            try invoice.pay()
            try order.complete(invoiceId: invoice.id)
            _ = invoice.pullEvents()
        }
        try await deliver(sut, payload(sut, status: "success", paymentId: "pay-1", transactionId: "tx-1"))
        #expect(eventKinds(sut).isEmpty)
        #expect(try await sut.invoices.fetch(byId: sut.invoiceId)?.transactionId == "tx-1")
    }

    // MARK: Payload from the gateway

    @Test("payload: info comes from the raw JSON, order_id is required")
    func payloadFromStatus() {
        let status = PaymentStatus(
            orderId: "invoice-1", status: "failure", action: "pay", paymentId: "1", transactionId: "2",
            amount: nil, currency: nil, errorCode: "e", errorDescription: "d",
            rawPayload: #"{"order_id":"invoice-1","info":"more","status":"failure"}"#
        )
        let payload = HandleLiqPayCallbackCommand.Payload(status: status)
        #expect(payload?.info == "more")
        #expect(payload?.paymentReference == "2")
        #expect(HandleLiqPayCallbackCommand.Payload(status: PaymentStatus(
            orderId: nil, status: "success", action: nil, paymentId: nil, transactionId: nil,
            amount: nil, currency: nil, errorCode: nil, errorDescription: nil, rawPayload: nil
        )) == nil)
    }

    // MARK: Audit document shape

    @Test("audit document keeps JSON types: bool, integer, fraction, null, nested")
    func auditEncoding() throws {
        let fields = try FirestoreInvoiceStatusAuditStore.fields(fromJSON: """
        {"b":true,"i":29,"d":19.99,"n":null,"s":"x","a":[1,"y"],"o":{"k":false}}
        """)
        #expect(fields["b"] as? Bool == true)
        #expect(fields["i"] is Int64)
        #expect(fields["d"] as? Double == 19.99)
        #expect(fields["n"] is NSNull)
        #expect(fields["s"] as? String == "x")
        #expect((fields["a"] as? [Any])?.count == 2)
        #expect((fields["o"] as? [String: Any])?["k"] as? Bool == false)
        #expect(throws: (any Error).self) { _ = try FirestoreInvoiceStatusAuditStore.fields(fromJSON: "[1]") }
    }

    // MARK: HTTP edge

    private func withApp(_ sut: SUT, _ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            app.useErrorEnvelope()
            let gateway = FakePaymentGateway(configuration: LiqPayFixtures.configuration())
            let controller = PaymentCallbackController(gateway: gateway, handler: sut.handler)
            try app.grouped("api").register(collection: PaymentCallbackRouteV1(controller: controller))
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func form(_ fields: [(String, String)]) -> ByteBuffer {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        return ByteBuffer(string: body)
    }

    private func post(
        _ app: Application, fields: [(String, String)], _ check: (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.test(.POST, "api/v1/payments/liqpay/callback", beforeRequest: { req in
            req.headers.contentType = .urlEncodedForm
            req.body = form(fields)
        }, afterResponse: { res async throws in try check(res) })
    }

    @Test("HTTP: a signed callback answers 200 OK and applies the status")
    func httpSigned() async throws {
        let sut = try await makeSUT()
        try await withApp(sut) { app in
            let signed = LiqPayFixtures.callback(
                json: #"{"order_id":"\#(sut.invoiceId)","status":"success","payment_id":77,"transaction_id":77,"info":"i"}"#
            )
            try await post(app, fields: [("data", signed.data), ("signature", signed.signature)]) { res in
                #expect(res.status == .ok)
                #expect(res.body.string == "OK")
            }
            let s = try await state(sut)
            #expect(s.invoice == .paid && s.order == .completed && s.session == .success)

            // LiqPay retry: still 200, nothing doubled.
            try await post(app, fields: [("data", signed.data), ("signature", signed.signature)]) { res in
                #expect(res.status == .ok)
            }
            #expect(await sut.audit.rows.count == 1)
            #expect(try await sut.sessions.fetch(byId: sut.invoiceId)?.transactionId == "77")
        }
    }

    @Test("HTTP: bad signature 401, missing signature 401, malformed 400")
    func httpRejections() async throws {
        let sut = try await makeSUT()
        try await withApp(sut) { app in
            let good = LiqPayFixtures.callback(json: #"{"order_id":"\#(sut.invoiceId)","status":"success"}"#)
            let forged = LiqPayFixtures.callback(
                json: #"{"order_id":"\#(sut.invoiceId)","status":"success"}"#, privateKey: "someone_elses_key"
            )
            let noOrder = LiqPayFixtures.callback(json: #"{"status":"success"}"#)
            let notJSON = LiqPayFixtures.callback(json: "this is not json")

            try await post(app, fields: [("data", good.data), ("signature", forged.signature)]) { #expect($0.status == .unauthorized) }
            try await post(app, fields: [("data", good.data)]) { #expect($0.status == .unauthorized) }
            try await post(app, fields: [("data", good.data), ("signature", "")]) { #expect($0.status == .unauthorized) }
            try await post(app, fields: [("signature", good.signature)]) { #expect($0.status == .badRequest) }
            try await post(app, fields: []) { #expect($0.status == .badRequest) }
            try await post(app, fields: [("data", "%%%"), ("signature", "x")]) { #expect($0.status == .unauthorized) }
            try await post(app, fields: [("data", notJSON.data), ("signature", notJSON.signature)]) { #expect($0.status == .badRequest) }
            try await post(app, fields: [("data", noOrder.data), ("signature", noOrder.signature)]) { #expect($0.status == .badRequest) }

            // None of it touched the purchase.
            let s = try await state(sut)
            #expect(s.invoice == .pending && s.order == .created && s.session == .pending)
            #expect(await sut.audit.rows.isEmpty)
        }
    }

    @Test("HTTP: an unknown invoice is still 200")
    func httpUnknownInvoice() async throws {
        let sut = try await makeSUT()
        try await withApp(sut) { app in
            let signed = LiqPayFixtures.callback(json: #"{"order_id":"invoice-nope","status":"success","payment_id":1}"#)
            try await post(app, fields: [("data", signed.data), ("signature", signed.signature)]) {
                #expect($0.status == .ok)
            }
        }
    }
}
