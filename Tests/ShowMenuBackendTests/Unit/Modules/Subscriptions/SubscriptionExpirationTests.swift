import Foundation
import Logging
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// The daily expiration job (S15): window math at the boundaries, per-subscription units of work,
/// idempotent re-runs, tolerance of optimistic-concurrency conflicts, and the reconcile pass.
@Suite("Subscription expiration job")
struct SubscriptionExpirationTests {
    typealias F = SubscriptionFixtures

    /// Millisecond-aligned, so `Timestamp(exact:)` round-trips every offset below exactly.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private static let day: TimeInterval = 86_400
    private static let ms: TimeInterval = 0.001

    // MARK: Fixtures

    private struct SUT {
        let subscriptions: InMemoryDataSource<SubscriptionModel>
        let invoices: InMemoryDataSource<InvoiceModel>
        let job: CheckExpiredSubscriptionsJob
        let uow: StubUnitOfWork

        func stored(_ id: Subscription.Id) async throws -> SubscriptionModel? {
            try await subscriptions.fetch(byId: id.rawValue)
        }

        func dispatched(_ kind: String) -> Int {
            uow.dispatchedEvents.compactMap { ($0 as? SubscriptionEvent)?.kind.rawValue }.filter { $0 == kind }.count
        }
    }

    /// Reads the in-memory store like the Firestore scan would: `active`, due by the cutoff, oldest first.
    private struct StoreSubscriptionSource: ExpiringSubscriptionSource {
        let store: InMemoryDataSource<SubscriptionModel>
        func activeSubscriptions(expiringBy cutoff: Date, limit: Int) async throws -> [SubscriptionReference] {
            try await store.query(DataSourceQuery()).items
                .filter { $0.status == .active && $0.expiresAt.asDate <= cutoff }
                .sorted { $0.expiresAt.asDate < $1.expiresAt.asDate }
                .prefix(limit)
                .map { SubscriptionReference(accountId: $0.accountId, id: .init(rawValue: $0.id), expiresAt: $0.expiresAt.asDate) }
        }
    }

    /// A scan that returns a fixed (stale) list, whatever the store holds now.
    private struct FrozenSubscriptionSource: ExpiringSubscriptionSource {
        let references: [SubscriptionReference]
        func activeSubscriptions(expiringBy cutoff: Date, limit: Int) async throws -> [SubscriptionReference] { references }
    }

    private struct StoreInvoiceSource: PaidInvoiceSource {
        let store: InMemoryDataSource<InvoiceModel>
        func paidInvoices(updatedSince since: Date, limit: Int) async throws -> [Invoice.Id] {
            try await store.query(DataSourceQuery()).items
                .filter { $0.status == .paid && $0.updatedAt.asDate >= since }
                .prefix(limit)
                .map { Invoice.Id(rawValue: $0.id) }
        }
    }

    /// Wraps the real repository; `update` of the listed ids fails like a lost compare-and-set.
    private struct ConflictingSubscriptionRepository: SubscriptionRepository {
        typealias Entity = Subscription
        typealias Model = SubscriptionModel
        let inner: FirestoreSubscriptionRepository
        let conflicting: Set<String>

        var mapper: any Mapper<Subscription, SubscriptionModel, SubscriptionDTO> { inner.mapper }
        var context: any UnitOfWorkContext { inner.context }

        func fetch(byId id: Subscription.Id) async throws -> Subscription? { try await inner.fetch(byId: id) }
        func fetch(accountId: String, id: Subscription.Id) async throws -> Subscription? {
            try await inner.fetch(accountId: accountId, id: id)
        }
        func find(accountId: String, orderId: String) async throws -> Subscription? {
            try await inner.find(accountId: accountId, orderId: orderId)
        }
        func doInsert(entities: [Subscription]) async throws { try await inner.doInsert(entities: entities) }
        func doUpdate(entities: [Subscription]) async throws {
            if let hit = entities.first(where: { conflicting.contains($0.id.rawValue) }) {
                throw ConcurrencyError.versionConflict(
                    entity: "Subscription", id: hit.id.rawValue, expected: .none, actual: .none
                )
            }
            try await inner.doUpdate(entities: entities)
        }
        func doDelete(entities: [Subscription]) async throws { try await inner.doDelete(entities: entities) }
    }

    private func makeSUT(
        subscriptions seeded: [Subscription] = [],
        invoices seededInvoices: [Invoice] = [],
        frozen: [SubscriptionReference]? = nil,
        conflicting: Set<String> = [],
        now override: Date? = nil,
        reconcileWindow: TimeInterval = CheckExpiredSubscriptionsJob.defaultReconcileWindow
    ) async throws -> SUT {
        let moment = override ?? now
        let logger = Logger(label: "test")
        let matches: @Sendable (SubscriptionModel, DataSourceFilter) -> Bool = { model, filter in
            filter.field == "orderId" ? model.orderId == (filter.value as? String) : true
        }
        let subscriptions = InMemoryDataSource<SubscriptionModel>(id: { $0.id }, matchesFilter: matches)
        let invoices = InMemoryDataSource<InvoiceModel>(id: { $0.id })
        for subscription in seeded { await subscriptions.seed(SubscriptionMapper().toModel(entity: subscription)) }
        for invoice in seededInvoices { await invoices.seed(InvoiceMapper().toModel(entity: invoice)) }

        let invoiceRepository: RepositoryFactory<any InvoiceRepository> = { ctx in
            FirestoreInvoiceRepository(mapper: InvoiceMapper(), dataSourceFactory: { _, _ in invoices }, context: ctx)
        }
        let subscriptionRepository: RepositoryFactory<any SubscriptionRepository> = { ctx in
            let real = FirestoreSubscriptionRepository(
                mapper: SubscriptionMapper(), dataSourceFactory: { _, _ in subscriptions }, context: ctx,
                directTransaction: { "direct" }
            )
            return conflicting.isEmpty ? real : ConflictingSubscriptionRepository(inner: real, conflicting: conflicting)
        }
        let uow = StubUnitOfWork()
        let job = CheckExpiredSubscriptionsJob(
            unitOfWork: uow,
            subscriptions: frozen.map { FrozenSubscriptionSource(references: $0) } ?? StoreSubscriptionSource(store: subscriptions),
            invoices: StoreInvoiceSource(store: invoices),
            expireUseCaseFactory: { ctx in
                ExpireSubscriptionUseCase(
                    context: ctx, subscriptionRepositoryFactory: subscriptionRepository, now: { moment }, logger: logger
                )
            },
            reconcileUseCaseFactory: { ctx in
                ReconcileSubscriptionUseCase(
                    context: ctx, invoiceRepositoryFactory: invoiceRepository,
                    subscriptionRepositoryFactory: subscriptionRepository,
                    activate: ActivateSubscriptionUseCase(
                        context: ctx, invoiceRepositoryFactory: invoiceRepository,
                        subscriptionRepositoryFactory: subscriptionRepository, now: { moment }, logger: logger
                    ),
                    logger: logger
                )
            },
            now: { moment },
            reconcileWindow: reconcileWindow,
            logger: logger
        )
        return SUT(subscriptions: subscriptions, invoices: invoices, job: job, uow: uow)
    }

    /// An active subscription of its own order, expiring `offset` seconds from `now`.
    private func subscription(_ offset: TimeInterval, status: SubscriptionStatus = .active) -> Subscription {
        F.subscription(
            status: status, expiresAt: now.addingTimeInterval(offset), orderId: Order.Id.generate().rawValue
        )
    }

    private func paidInvoice(transactionId: String? = "tx-1", at moment: Date) throws -> Invoice {
        let invoice = try PurchaseFixtures.makeOrder().createInvoice()
        try invoice.pay(transactionId: transactionId, now: moment)
        _ = invoice.pullEvents()
        return invoice
    }

    // MARK: Aggregate: window math at the boundaries

    @Test("expireIfNeeded: both boundaries are inclusive and nothing else changes")
    func boundaries() throws {
        func outcome(_ offset: TimeInterval, _ status: SubscriptionStatus = .active) throws -> (ExpirationOutcome, Subscription) {
            let sub = subscription(offset, status: status)
            return (try sub.expireIfNeeded(now: now), sub)
        }
        // exactly now - 1 day: expired
        let (a, subA) = try outcome(-Self.day)
        #expect(a == .expired && subA.status == .expired)
        // one millisecond later: only a warning, state untouched
        let (b, subB) = try outcome(-Self.day + Self.ms)
        #expect(b == .expiring && subB.status == .active)
        // exactly now: still a warning
        let (c, _) = try outcome(0)
        #expect(c == .expiring)
        // one millisecond ahead: nothing to do yet
        let (d, subD) = try outcome(Self.ms)
        #expect(d == .unchanged && subD.pullEvents().isEmpty)
        // long gone: expired
        let (e, _) = try outcome(-30 * Self.day)
        #expect(e == .expired)
    }

    @Test("expireIfNeeded: expiring raises the event but leaves expiresAt, status and updatedAt alone")
    func expiringIsPure() throws {
        let sub = subscription(-3600)
        let before = (sub.status, sub.expiresAt, sub.updatedAt)
        #expect(try sub.expireIfNeeded(now: now) == .expiring)
        #expect((sub.status, sub.expiresAt, sub.updatedAt) == before)
        #expect(sub.pullEvents().map(\.kind) == [.subscriptionExpiring])
    }

    @Test("expireIfNeeded: expired raises subscription.expired once; non-active subscriptions are untouched")
    func expiredEvent() throws {
        let sub = subscription(-2 * Self.day)
        #expect(try sub.expireIfNeeded(now: now) == .expired)
        #expect(sub.pullEvents().map(\.kind) == [.subscriptionExpired])
        #expect(try sub.expireIfNeeded(now: now) == .unchanged)

        for status in [SubscriptionStatus.suspended, .cancelled, .expired] {
            let other = subscription(-5 * Self.day, status: status)
            #expect(try other.expireIfNeeded(now: now) == .unchanged)
            #expect(other.status == status && other.pullEvents().isEmpty)
        }
    }

    // MARK: Job: expiry

    @Test("a run expires, warns, scans the rest and counts exactly that")
    func windows() async throws {
        let expired = subscription(-Self.day)                 // exactly now - 1 day
        let longGone = subscription(-10 * Self.day)
        let justInside = subscription(-Self.day + Self.ms)    // warning
        let atNow = subscription(0)                           // warning
        let ahead = subscription(Self.ms)                     // scanned, untouched
        let tomorrow = subscription(Self.day)                 // scanned (cutoff is inclusive), untouched
        let later = subscription(Self.day + Self.ms)          // not even scanned
        let suspended = subscription(-3 * Self.day, status: .suspended) // not active: not scanned
        let sut = try await makeSUT(subscriptions: [expired, longGone, justInside, atNow, ahead, tomorrow, later, suspended])

        let summary = try await sut.job.run()

        #expect(summary == ExpirationSummary(scanned: 6, expired: 2, expiring: 2, reconciled: 0))
        #expect(try await sut.stored(expired.id)?.status == .expired)
        #expect(try await sut.stored(longGone.id)?.status == .expired)
        for untouched in [justInside, atNow, ahead, tomorrow, later] {
            #expect(try await sut.stored(untouched.id)?.status == .active)
        }
        #expect(try await sut.stored(suspended.id)?.status == .suspended)
        // Only the two expirations were written (the warnings write nothing).
        #expect(await sut.subscriptions.updatedModels.count == 2)
        #expect(sut.dispatched("subscription.expired") == 2)
        #expect(sut.dispatched("subscription.expiring") == 2)
    }

    @Test("re-running changes no document: expirations are done, warnings repeat without writes")
    func idempotentRerun() async throws {
        let expired = subscription(-2 * Self.day)
        let expiring = subscription(-3600)
        let sut = try await makeSUT(subscriptions: [expired, expiring])

        let first = try await sut.job.run()
        let afterFirst = try await sut.subscriptions.query(DataSourceQuery()).items.sorted { $0.id < $1.id }
        let second = try await sut.job.run()
        let afterSecond = try await sut.subscriptions.query(DataSourceQuery()).items.sorted { $0.id < $1.id }

        #expect(first == ExpirationSummary(scanned: 2, expired: 1, expiring: 1, reconciled: 0))
        #expect(second == ExpirationSummary(scanned: 1, expired: 0, expiring: 1, reconciled: 0))
        #expect(afterFirst == afterSecond)
        #expect(await sut.subscriptions.updatedModels.count == 1)
    }

    @Test("a stale scan does not expire a subscription that was renewed in the meantime")
    func staleSnapshotIsRechecked() async throws {
        let renewed = subscription(20 * Self.day) // the store holds the renewed document
        let stale = SubscriptionReference(
            accountId: PurchaseFixtures.accountId, id: renewed.id, expiresAt: now.addingTimeInterval(-2 * Self.day)
        )
        let sut = try await makeSUT(subscriptions: [renewed], frozen: [stale])

        let summary = try await sut.job.run()

        #expect(summary == ExpirationSummary(scanned: 1, expired: 0, expiring: 0, reconciled: 0))
        #expect(try await sut.stored(renewed.id)?.status == .active)
        #expect(await sut.subscriptions.updatedModels.isEmpty)
    }

    @Test("a lost compare-and-set on one subscription is skipped; the rest of the run completes")
    func conflictIsTolerated() async throws {
        let contested = subscription(-3 * Self.day)
        let other = subscription(-4 * Self.day)
        let sut = try await makeSUT(subscriptions: [contested, other], conflicting: [contested.id.rawValue])

        let summary = try await sut.job.run()

        #expect(summary == ExpirationSummary(scanned: 2, expired: 1, expiring: 0, reconciled: 0))
        #expect(try await sut.stored(contested.id)?.status == .active) // next run re-evaluates it
        #expect(try await sut.stored(other.id)?.status == .expired)
        #expect(sut.dispatched("subscription.expired") == 1)
    }

    // MARK: Job: reconcile

    @Test("a paid invoice without a subscription gets one; a re-run creates nothing more")
    func reconcileCreates() async throws {
        let moment = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let invoice = try paidInvoice(at: moment)
        let sut = try await makeSUT(invoices: [invoice], now: moment)

        let first = try await sut.job.run()
        let second = try await sut.job.run()

        #expect(first == ExpirationSummary(scanned: 0, expired: 0, expiring: 0, reconciled: 1))
        #expect(second.reconciled == 0)
        let created = try #require(try await sut.stored(.derive(orderId: invoice.orderId.rawValue)))
        #expect(created.status == .active && created.accountId == invoice.accountId)
        #expect(created.lastPaymentRef == "tx-1")
        #expect(created.expiresAt.asDate.timeIntervalSince(SubscriptionDuration.monthly.add(to: moment)) < 0.002)
        #expect(await sut.subscriptions.insertedModels.count == 1)
        #expect(sut.dispatched("subscription.activated") == 1)
    }

    @Test("an invoice that already has a subscription (derived id, or a legacy random id) is left alone")
    func reconcileSkipsExisting() async throws {
        let moment = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let derivedInvoice = try paidInvoice(transactionId: "tx-new", at: moment)
        let legacyInvoice = try paidInvoice(transactionId: "tx-new", at: moment)
        let expiry = moment.addingTimeInterval(10 * Self.day)
        // `lastPaymentRef` differs from the invoice's payment, and the legacy one has none at all:
        // a blind re-run of the activation would extend both. The reconcile pass must not.
        let derived = F.subscription(
            expiresAt: expiry, orderId: derivedInvoice.orderId.rawValue, lastPaymentRef: "tx-old"
        )
        let legacy = F.subscription(
            expiresAt: expiry, orderId: legacyInvoice.orderId.rawValue, id: .init(rawValue: F.legacyId)
        )
        let sut = try await makeSUT(
            subscriptions: [derived, legacy], invoices: [derivedInvoice, legacyInvoice], now: moment
        )

        let summary = try await sut.job.run()

        #expect(summary.reconciled == 0)
        #expect(await sut.subscriptions.insertedModels.isEmpty)
        #expect(await sut.subscriptions.updatedModels.isEmpty)
        #expect(try await sut.stored(derived.id)?.expiresAt.asDate == expiry)
        #expect(try await sut.stored(legacy.id)?.expiresAt.asDate == expiry)
    }

    @Test("invoices that are not paid or have no plan line create nothing")
    func reconcileIgnoresOthers() async throws {
        let moment = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let pending = try PurchaseFixtures.makeOrder().createInvoice()
        let failed = try PurchaseFixtures.makeOrder().createInvoice()
        try failed.fail()
        let oneOff = try PurchaseFixtures.makeOrder(lines: [try PurchaseFixtures.product(duration: nil)]).createInvoice()
        try oneOff.pay(transactionId: "tx", now: moment)
        let sut = try await makeSUT(invoices: [pending, failed, oneOff], now: moment)

        #expect(try await sut.job.run().reconciled == 0)
        #expect(await sut.subscriptions.insertedModels.isEmpty)
    }

    @Test("the reconcile pass only looks back over its window (override widens it)")
    func reconcileWindow() async throws {
        let paidAt = Date(timeIntervalSince1970: 1_770_000_000)
        let invoice = try paidInvoice(at: paidAt)
        let later = paidAt.addingTimeInterval(30 * Self.day)
        let sut = try await makeSUT(invoices: [invoice], now: later)

        #expect(try await sut.job.run().reconciled == 0)
        #expect(try await sut.job.run(reconcileWindow: 60 * Self.day).reconciled == 1)
    }

    // MARK: HTTP

    @Test("POST /api/v1/subscriptions/jobs/check-expired answers the four-field summary")
    func endpoint() async throws {
        let sut = try await makeSUT(subscriptions: [subscription(-2 * Self.day), subscription(-60)])
        let app = try await Application.make(.testing)
        do {
            app.useErrorEnvelope()
            try app.grouped("api")
                .grouped(SchedulerAuthMiddleware(apiKey: "k", oidc: nil))
                .register(collection: SubscriptionJobRouteV1(controller: SubscriptionJobController(job: sut.job)))
            let tester = try app.testing()
            let path = "api/v1/subscriptions/jobs/check-expired"

            try await tester.test(.POST, path, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
            var headers = HTTPHeaders()
            headers.add(name: "X-Api-Key", value: "k")
            try await tester.test(.POST, path, headers: headers, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Int]
                #expect(json == ["scanned": 2, "expired": 1, "expiring": 1, "reconciled": 0])
            })
            try await tester.test(.POST, path + "?reconcileDays=0", headers: headers, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
            })
            try await tester.test(.POST, path + "?reconcileDays=30", headers: headers, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
