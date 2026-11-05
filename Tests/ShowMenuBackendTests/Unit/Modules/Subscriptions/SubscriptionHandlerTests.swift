import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// `InvoiceEvent` -> subscription: each handler action, idempotency on re-delivery, the
/// deterministic id, renewal math and the legacy (`sub:<random>`) lookup.
@Suite("Subscription invoice-event handler")
struct SubscriptionHandlerTests {
    typealias F = SubscriptionFixtures

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private struct SUT {
        let invoices: InMemoryDataSource<InvoiceModel>
        let subscriptions: InMemoryDataSource<SubscriptionModel>
        let handler: SubscriptionInvoiceEventHandler
        let invoice: Invoice
        let uow: StubUnitOfWork
    }


    /// An invoice already moved to `status` (paid with `transactionId` by default).
    private func makeSUT(
        invoice status: InvoiceStatus = .paid, transactionId: String? = "tx-1", seed: ((String) -> [SubscriptionModel])? = nil,
        lines: [OrderProduct]? = nil
    ) async throws -> SUT {
        let logger = Logger(label: "test")
        let invoices = InMemoryDataSource<InvoiceModel>(id: { $0.id })
        let matches: @Sendable (SubscriptionModel, DataSourceFilter) -> Bool = { model, filter in
            filter.field == "orderId" ? model.orderId == (filter.value as? String) : true
        }
        let subscriptions = InMemoryDataSource<SubscriptionModel>(id: { $0.id }, matchesFilter: matches)
        let invoice = try PurchaseFixtures.makeOrder(lines: lines).createInvoice()
        switch status {
        case .pending: break
        case .paid: try invoice.pay(transactionId: transactionId)
        case .failed: try invoice.fail()
        case .cancelled: try invoice.cancel()
        case .refunded: try invoice.pay(transactionId: transactionId); try invoice.refund()
        }
        _ = invoice.pullEvents()
        await invoices.seed(InvoiceMapper().toModel(entity: invoice))
        for model in seed?(invoice.orderId.rawValue) ?? [] { await subscriptions.seed(model) }

        let invoiceRepository: RepositoryFactory<any InvoiceRepository> = { ctx in
            FirestoreInvoiceRepository(mapper: InvoiceMapper(), dataSourceFactory: { _, _ in invoices }, context: ctx)
        }
        let subscriptionRepository: RepositoryFactory<any SubscriptionRepository> = { ctx in
            FirestoreSubscriptionRepository(
                mapper: SubscriptionMapper(), dataSourceFactory: { _, _ in subscriptions }, context: ctx,
                directTransaction: { "direct" }
            )
        }
        let fixedNow = now
        let uow = StubUnitOfWork()
        let handler = SubscriptionInvoiceEventHandler(
            unitOfWork: uow,
            activateUseCaseFactory: { ctx in
                ActivateSubscriptionUseCase(
                    context: ctx, invoiceRepositoryFactory: invoiceRepository,
                    subscriptionRepositoryFactory: subscriptionRepository, now: { fixedNow }, logger: logger
                )
            },
            suspendUseCaseFactory: { ctx in
                SuspendSubscriptionUseCase(
                    context: ctx, invoiceRepositoryFactory: invoiceRepository,
                    subscriptionRepositoryFactory: subscriptionRepository, now: { fixedNow }, logger: logger
                )
            },
            cancelUseCaseFactory: { ctx in
                CancelSubscriptionUseCase(
                    context: ctx, invoiceRepositoryFactory: invoiceRepository,
                    subscriptionRepositoryFactory: subscriptionRepository, now: { fixedNow }, logger: logger
                )
            },
            logger: logger
        )
        return SUT(invoices: invoices, subscriptions: subscriptions, handler: handler, invoice: invoice, uow: uow)
    }

    private func event(_ kind: InvoiceEventKind, _ sut: SUT) -> InvoiceEvent {
        .semantic(kind, aggregateId: sut.invoice.id)
    }

    /// A stored subscription of `orderId`; `legacy` gives it a random `sub:<uuid>` id instead of the derived one.
    private func existing(
        _ orderId: String, status: SubscriptionStatus = .active, expiresAt: Date, legacy: Bool = false,
        ref: String? = "tx-1", suspensionReason: String? = nil
    ) -> SubscriptionModel {
        SubscriptionMapper().toModel(entity: F.subscription(
            status: status, expiresAt: expiresAt, orderId: orderId,
            id: legacy ? .init(rawValue: F.legacyId) : nil, lastPaymentRef: ref, suspensionReason: suspensionReason
        ))
    }

    private func derivedId(_ sut: SUT) -> String { Subscription.Id.derive(orderId: sut.invoice.orderId.rawValue).rawValue }

    // MARK: invoice.paid

    @Test("paid creates the subscription: derived id, plan from the line, one period from now")
    func paidCreates() async throws {
        let sut = try await makeSUT()
        await sut.handler.handle(event: event(.invoicePaid, sut))

        let created = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(created.status == .active)
        #expect(created.planId == "plan-1" && created.orderId == sut.invoice.orderId.rawValue)
        #expect(created.accountId == PurchaseFixtures.accountId)
        #expect(created.startedAt.asDate == Date(timeIntervalSince1970: 1_770_000_000))
        #expect(created.expiresAt.asDate == SubscriptionDuration.monthly.add(to: now))
        #expect(created.lastPaymentRef == "tx-1" && created.version == 1)
        #expect(created.suspensionReason == nil && created.cancellationReason == nil)
        let kinds = sut.uow.dispatchedEvents.compactMap { ($0 as? SubscriptionEvent)?.kind.rawValue }
        #expect(kinds.contains("subscription.activated"))
    }

    @Test("a re-delivered or duplicated paid event leaves exactly one document and does not extend")
    func paidTwice() async throws {
        let sut = try await makeSUT()
        let first = event(.invoicePaid, sut)
        await sut.handler.handle(event: first)
        await sut.handler.handle(event: first)
        await sut.handler.handle(event: event(.invoicePaid, sut)) // a fresh event for the same payment

        #expect(await sut.subscriptions.insertedModels.count == 1)
        #expect(await sut.subscriptions.updatedModels.isEmpty)
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: now))
    }

    @Test("an invoice without a transaction id still activates exactly once")
    func paidWithoutTransactionId() async throws {
        let sut = try await makeSUT(transactionId: nil)
        await sut.handler.handle(event: event(.invoicePaid, sut))
        await sut.handler.handle(event: event(.invoicePaid, sut))
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.lastPaymentRef == "\(sut.invoice.id.rawValue):paid")
        let inserted = await sut.subscriptions.insertedModels
        #expect(inserted.count == 1 && doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: now))
    }

    @Test("paid does nothing when the invoice has moved on (refunded) or is unknown")
    func paidSkipped() async throws {
        let refunded = try await makeSUT(invoice: .refunded)
        await refunded.handler.handle(event: event(.invoicePaid, refunded))
        #expect(await refunded.subscriptions.insertedModels.isEmpty)

        let unknown = try await makeSUT()
        await unknown.handler.handle(event: .semantic(.invoicePaid, aggregateId: Invoice.Id.generate()))
        #expect(await unknown.subscriptions.insertedModels.isEmpty)
    }

    @Test("a non-plan invoice (no duration) creates nothing")
    func paidWithoutPlanLine() async throws {
        let sut = try await makeSUT(lines: [try PurchaseFixtures.product(duration: nil)])
        await sut.handler.handle(event: event(.invoicePaid, sut))
        #expect(await sut.subscriptions.insertedModels.isEmpty)
    }

    // MARK: invoice.renewed

    @Test("renewed extends by one period from the current expiry")
    func renewedExtends() async throws {
        let expiry = now.addingTimeInterval(10 * 86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing($0, expiresAt: expiry, ref: "tx-1")] })
        await sut.handler.handle(event: event(.invoiceRenewed, sut))

        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: expiry))
        #expect(doc.lastPaymentRef == "tx-2" && doc.status == .active)
        #expect(await sut.subscriptions.insertedModels.isEmpty)
    }

    @Test("renewed twice for the same payment extends once")
    func renewedIdempotent() async throws {
        let expiry = now.addingTimeInterval(10 * 86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing($0, expiresAt: expiry, ref: "tx-1")] })
        let renewed = event(.invoiceRenewed, sut)
        await sut.handler.handle(event: renewed)
        await sut.handler.handle(event: renewed)
        await sut.handler.handle(event: event(.invoiceRenewed, sut))

        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: expiry))
        #expect(await sut.subscriptions.updatedModels.count == 1)
    }

    @Test("two successive renewals add two periods")
    func renewedTwice() async throws {
        let expiry = now.addingTimeInterval(10 * 86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing($0, expiresAt: expiry, ref: "tx-1")] })
        await sut.handler.handle(event: event(.invoiceRenewed, sut))

        // The next recurring charge: the invoice now carries tx-3.
        let invoice = try #require(try await sut.invoices.fetch(byId: sut.invoice.id.rawValue))
        let entity = try InvoiceMapper().toEntity(model: invoice)
        try entity.renew(transactionId: "tx-3")
        await sut.invoices.seed(InvoiceMapper().toModel(entity: entity))
        await sut.handler.handle(event: event(.invoiceRenewed, sut))

        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: SubscriptionDuration.monthly.add(to: expiry)))
    }

    @Test("renewed with no subscription creates one (heals a lost activation)")
    func renewedCreates() async throws {
        let sut = try await makeSUT(transactionId: "tx-2")
        await sut.handler.handle(event: event(.invoiceRenewed, sut))
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.status == .active && doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: now))
    }

    @Test("renewed reactivates a suspended subscription (a failed charge that was retried successfully)")
    func renewedReactivates() async throws {
        let expiry = now.addingTimeInterval(5 * 86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing(
            $0, status: .suspended, expiresAt: expiry, ref: "tx-1", suspensionReason: "Payment failed"
        )] })
        await sut.handler.handle(event: event(.invoiceRenewed, sut))
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.status == .active && doc.suspensionReason == nil)
        #expect(doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: expiry))
    }

    @Test("a payment event for a cancelled subscription changes nothing")
    func renewedOnCancelled() async throws {
        let expiry = now.addingTimeInterval(-86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing($0, status: .cancelled, expiresAt: expiry, ref: "tx-1")] })
        await sut.handler.handle(event: event(.invoiceRenewed, sut))
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.status == .cancelled && doc.expiresAt.asDate == expiry && doc.lastPaymentRef == "tx-1")
        #expect(await sut.subscriptions.updatedModels.isEmpty)
    }

    // MARK: Legacy documents

    @Test("a legacy sub:<uuid> document of the order is found by orderId and extended in place")
    func legacyLookup() async throws {
        let expiry = now.addingTimeInterval(3 * 86_400)
        let sut = try await makeSUT(transactionId: "tx-2", seed: { [existing($0, expiresAt: expiry, legacy: true, ref: nil)] })
        await sut.handler.handle(event: event(.invoiceRenewed, sut))

        #expect(await sut.subscriptions.insertedModels.isEmpty)
        let doc = try #require(try await sut.subscriptions.fetch(byId: F.legacyId))
        #expect(doc.id == F.legacyId && doc.expiresAt.asDate == SubscriptionDuration.monthly.add(to: expiry))
        #expect(try await sut.subscriptions.fetch(byId: derivedId(sut)) == nil)
    }

    // MARK: failed / refunded / cancelled / charge_failed / unsubscribed

    private static let statusRows: [(InvoiceEventKind, SubscriptionStatus, String)] = [
        (.invoiceFailed, .suspended, "Payment failed"),
        (.invoiceChargeFailed, .suspended, "Payment failed"),
        (.invoiceRefunded, .cancelled, "Payment refunded"),
        (.invoiceCancelled, .cancelled, "Payment cancelled"),
        (.invoiceUnsubscribed, .cancelled, "Payment unsubscribed"),
    ]

    @Test("each invoice event moves an active subscription with its reason", arguments: statusRows)
    func statusChanges(row: (InvoiceEventKind, SubscriptionStatus, String)) async throws {
        let expiry = now.addingTimeInterval(10 * 86_400)
        let sut = try await makeSUT(seed: { [existing($0, expiresAt: expiry)] })
        await sut.handler.handle(event: event(row.0, sut))

        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.status == row.1)
        #expect(row.1 == .suspended ? doc.suspensionReason == row.2 : doc.cancellationReason == row.2)
        #expect(doc.expiresAt.asDate == expiry) // paid time is never touched
    }

    @Test("failed / refunded for an order with no subscription is a no-op")
    func noSubscription() async throws {
        let sut = try await makeSUT()
        for kind in [InvoiceEventKind.invoiceFailed, .invoiceRefunded, .invoiceCancelled] {
            await sut.handler.handle(event: event(kind, sut))
        }
        let inserted = await sut.subscriptions.insertedModels, updated = await sut.subscriptions.updatedModels
        #expect(inserted.isEmpty && updated.isEmpty)
    }

    @Test("an invalid transition (cancelling an expired subscription) is logged and leaves it untouched")
    func invalidTransitionLeavesIt() async throws {
        let expiry = now.addingTimeInterval(-40 * 86_400)
        let sut = try await makeSUT(seed: { [existing($0, status: .expired, expiresAt: expiry)] })
        await sut.handler.handle(event: event(.invoiceRefunded, sut))
        let doc = try #require(try await sut.subscriptions.fetch(byId: derivedId(sut)))
        #expect(doc.status == .expired && doc.expiresAt.asDate == expiry && doc.cancellationReason == nil)
    }

    @Test("lifecycle kinds are ignored")
    func lifecycleIgnored() async throws {
        let sut = try await makeSUT()
        for kind in [InvoiceEventKind.invoiceCreated, .invoiceUpdated, .invoiceDeleted] {
            await sut.handler.handle(event: event(kind, sut))
        }
        #expect(await sut.subscriptions.insertedModels.isEmpty)
    }

    @Test("registered on the real dispatcher it receives an InvoiceEvent and acts on it")
    func viaDispatcher() async throws {
        let sut = try await makeSUT()
        let dispatcher = InMemoryDomainEventDispatcher(logger: Logger(label: "test"))
        await dispatcher.register(handler: sut.handler)
        await dispatcher.dispatch(event: event(.invoicePaid, sut))
        #expect(try await sut.subscriptions.fetch(byId: derivedId(sut)) != nil)
    }
}
