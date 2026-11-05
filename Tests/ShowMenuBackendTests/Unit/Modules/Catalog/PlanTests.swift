import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

private func usd(_ amount: Double, symbol: String? = "$", base: Int? = 100, digits: Int? = 2) throws -> Price {
    try Price(currency: Currency(name: "USD", symbol: symbol, base: base, digits: digits), amount: amount)
}

private func samplePrices() throws -> [PlanPrice] {
    [
        PlanPrice(price: try usd(2900), duration: .monthly),
        PlanPrice(price: try usd(29000), duration: .yearly),
    ]
}

private func sampleFeatures() -> [PlanFeature] {
    [PlanFeature(featureId: .init(rawValue: "feature-1"), quota: FeatureQuota(unit: .count, limit: 100))]
}

@Suite("Plan aggregate")
struct PlanAggregateTests {

    private func makePlan(prices: [PlanPrice]? = nil, features: [PlanFeature]? = nil, sku: String = "SKU-1") throws -> Plan {
        try Plan.create(
            SKU: sku,
            name: LocalizedString(["en": "Pro"]),
            description: LocalizedString(["en": "Desc"]),
            isActive: false,
            prices: try prices ?? samplePrices(),
            features: features ?? sampleFeatures()
        )
    }

    @Test("create: prefixed id, equal timestamps, semantic PlanCreated recorded")
    func create() throws {
        let plan = try makePlan()
        #expect(plan.id.rawValue.hasPrefix("plan-"))
        #expect(plan.createdAt == plan.updatedAt)
        #expect(plan.pullEvents().map(\.kind) == [.planAdded])
    }

    @Test("invariants are ValidationErrors",
          arguments: [
            ("", true, true, Plan.Error.skuRequired),
            ("S", false, true, Plan.Error.pricesRequired),
            ("S", true, false, Plan.Error.featuresRequired),
          ])
    func invariants(sku: String, withPrices: Bool, withFeatures: Bool, expected: Plan.Error) throws {
        #expect(throws: expected) {
            try makePlan(prices: withPrices ? nil : [], features: withFeatures ? nil : [], sku: sku)
        }
        #expect(expected is any ValidationError)
    }

    @Test("duplicate durations and duplicate feature ids are rejected")
    func duplicates() throws {
        #expect(throws: Plan.Error.duplicateDurations) {
            try makePlan(prices: [
                PlanPrice(price: try usd(1), duration: .monthly),
                PlanPrice(price: try usd(2), duration: .monthly),
            ])
        }
        #expect(throws: Plan.Error.duplicateFeatures) {
            try makePlan(features: sampleFeatures() + sampleFeatures())
        }
    }

    // MARK: D9 — duration + currency name + amount

    @Test("matches(price:) is true on equal duration, currency name and amount")
    func matchesExact() throws {
        let plan = try makePlan()
        #expect(plan.matches(price: PlanPrice(price: try usd(2900), duration: .monthly)))
        #expect(plan.matches(price: PlanPrice(price: try usd(29000), duration: .yearly)))
    }

    @Test("matches(price:) ignores symbol, base and digits (Flutter omits base/digits)")
    func matchesIgnoresCurrencyDetails() throws {
        let plan = try makePlan()
        let bare = try Price(currency: Currency(name: "USD"), amount: 2900)
        #expect(plan.matches(price: PlanPrice(price: bare, duration: .monthly)))
        let other = try usd(2900, symbol: "US$", base: 1, digits: 0)
        #expect(plan.matches(price: PlanPrice(price: other, duration: .monthly)))
    }

    @Test("matches(price:) is false on a different duration, currency name or amount")
    func matchesRejects() throws {
        let plan = try makePlan()
        #expect(!plan.matches(price: PlanPrice(price: try usd(2900), duration: .yearly)))
        #expect(!plan.matches(price: PlanPrice(price: try usd(2901), duration: .monthly)))
        let eur = try Price(currency: Currency(name: "EUR"), amount: 2900)
        #expect(!plan.matches(price: PlanPrice(price: eur, duration: .monthly)))
        #expect(!plan.matches(price: PlanPrice(price: try usd(2900), duration: .weekly)))
    }
}

@Suite("Plan create use case")
struct CreatePlanUseCaseTests {
    let mapper = PlanMapper()

    /// `ds` = `plans`, `skus` = `plan_skus` markers.
    private func makeSUT() -> (
        ds: InMemoryDataSource<PlanModel>,
        skus: InMemoryDataSource<PlanSKUModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = InMemoryDataSource<PlanModel>(id: { $0.id }, matchesFilter: { model, filter in
            filter.field == "SKU" && filter.op == .equal && (filter.value as? String) == model.SKU
        })
        let skus = InMemoryDataSource<PlanSKUModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        return (ds, skus, collector, StubUnitOfWorkContext(transaction: "stub", collector: collector))
    }

    private func makeUseCase(
        _ ds: InMemoryDataSource<PlanModel>,
        _ skus: InMemoryDataSource<PlanSKUModel>,
        _ ctx: StubUnitOfWorkContext
    ) -> CreatePlanUseCase {
        let mapper = self.mapper
        return CreatePlanUseCase(
            context: ctx,
            repositoryFactory: { ctx in
                FirestorePlanRepository(
                    mapper: mapper,
                    dataSourceFactory: { _, _ in ds },
                    skuDataSourceFactory: { _, _ in skus },
                    context: ctx
                )
            },
            mapper: mapper,
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
    }

    private func payload(
        sku: String? = "SKU-1",
        isActive: Bool? = false,
        prices: [CreatePlanCommand.PriceInput]? = nil,
        features: [CreatePlanCommand.FeatureInput]? = nil
    ) -> CreatePlanCommand.Payload {
        CreatePlanCommand.Payload(
            SKU: sku,
            name: ["en": "Pro", "uk": "Про"],
            description: ["en": "All features"],
            isActive: isActive,
            prices: prices ?? [.init(
                price: PriceDTO(currencyName: "USD", currencySymbol: "$", currencyBase: 100, currencyDigits: 2, amount: 2900),
                duration: "monthly"
            )],
            features: features ?? [.init(featureId: "feature-1", quota: .init(unit: "count", limit: 100))]
        )
    }

    @Test("happy path: DTO in Node's shape, one model, lifecycle + semantic events")
    func happyPath() async throws {
        let (ds, skus, collector, ctx) = makeSUT()
        let dto = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload()))

        #expect(dto.id.hasPrefix("plan-"))
        #expect(dto.SKU == "SKU-1")
        #expect(dto.isActive == false)
        #expect(dto.prices.first?.duration == "monthly")
        #expect(dto.prices.first?.price.currency.name == "USD")
        #expect(dto.features.first?.quota.unit == .count)
        #expect(await ds.insertedModels.count == 1)
        #expect(await ds.insertedModels.first?.version == 1)

        let kinds = try await collector.drain().map { try #require($0 as? PlanEvent).kind }
        #expect(kinds.contains(.planAdded))
        #expect(kinds.contains(.created))
    }

    @Test("create reserves the SKU: a plan_skus marker is written with the plan")
    func reservesMarker() async throws {
        let (ds, skus, _, ctx) = makeSUT()
        let dto = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload(sku: "A/b")))
        let marker = try #require(await skus.insertedModels.first)
        #expect(marker.id == PlanSKUModel.documentId(for: "A/b"))
        #expect(!marker.id.contains("/"))
        #expect(marker.sku == "A/b" && marker.planId == dto.id)
        #expect(PlanSKUModel.documentId(for: "A") != PlanSKUModel.documentId(for: "a"))
    }

    @Test("a taken marker → PlanSKUAlreadyExistsError (409), nothing inserted")
    func duplicateViaMarker() async throws {
        let (ds, skus, _, ctx) = makeSUT()
        _ = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload()))
        // A second create sees the marker even if the plan doc were not visible.
        await ds.reset()

        await #expect(throws: PlanSKUAlreadyExistsError(sku: "SKU-1")) {
            try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload()))
        }
        #expect(await ds.insertedModels.isEmpty)
        #expect(await skus.insertedModels.count == 1)
        #expect(await ds.queries.isEmpty) // answered by the marker, no query needed
        #expect(HTTPErrorMapping.map(PlanSKUAlreadyExistsError(sku: "x")).status.code == 409)
    }

    @Test("a legacy plan without a marker is caught by the SKU query backstop")
    func duplicateViaLegacyQuery() async throws {
        let (ds, skus, _, ctx) = makeSUT()
        let legacy = try Plan.create(
            SKU: "SKU-1", name: LocalizedString(["en": "x"]), description: LocalizedString(["en": "x"]),
            isActive: true, prices: try samplePrices(), features: sampleFeatures()
        )
        await ds.seed(mapper.toModel(entity: legacy))

        await #expect(throws: PlanSKUAlreadyExistsError(sku: "SKU-1")) {
            try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload()))
        }
        let filter = try #require(await ds.queries.last?.filters.first)
        #expect(filter.field == "SKU" && filter.op == .equal)
        #expect(await ds.insertedModels.isEmpty)
        #expect(await skus.insertedModels.isEmpty)
    }

    @Test("a different SKU is not a duplicate")
    func differentSKU() async throws {
        let (ds, skus, _, ctx) = makeSUT()
        _ = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload(sku: "A")))
        _ = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: payload(sku: "B")))
        #expect(await ds.insertedModels.count == 2)
    }

    @Test("validation failures throw ValidationErrors (422) and persist nothing",
          arguments: [
            "sku", "prices", "features", "duration", "unit", "dupDurations", "dupFeatures", "amount",
          ])
    func validation(case name: String) async throws {
        let (ds, skus, _, ctx) = makeSUT()
        let price = { (d: String, a: Double) in
            CreatePlanCommand.PriceInput(price: PriceDTO(currencyName: "USD", amount: a), duration: d)
        }
        let feature = { (id: String, unit: String) in
            CreatePlanCommand.FeatureInput(featureId: id, quota: .init(unit: unit, limit: 1))
        }
        let p: CreatePlanCommand.Payload = switch name {
        case "sku": payload(sku: "")
        case "prices": payload(prices: [])
        case "features": payload(features: [])
        case "duration": payload(prices: [price("hourly", 1)])
        case "unit": payload(features: [feature("f", "bytes")])
        case "dupDurations": payload(prices: [price("monthly", 1), price("monthly", 2)])
        case "dupFeatures": payload(features: [feature("f", "count"), feature("f", "level")])
        default: payload(prices: [price("monthly", 0)])
        }
        do {
            _ = try await makeUseCase(ds, skus, ctx).execute(params: .init(payload: p))
            Issue.record("expected a ValidationError")
        } catch {
            #expect(error is any ValidationError, "got \(error)")
        }
        #expect(await ds.insertedModels.isEmpty)
    }
}

/// Resolves the HTTP status the error middleware would answer.
private enum HTTPStatusHintTable {
    static func status(of error: any Error) -> UInt {
        HTTPErrorMapping.map(error).status.code
    }
}

@Suite("Plan query handlers")
struct PlanQueryHandlerTests {
    let mapper = PlanMapper()

    private func seeded() async throws -> InMemoryDataSource<PlanModel> {
        let ds = InMemoryDataSource<PlanModel>(id: { $0.id })
        for (n, t) in [("b", 2_000.0), ("a", 3_000.0), ("c", 1_000.0)] {
            let plan = try Plan.create(
                SKU: "SKU-\(n)", name: LocalizedString(["en": n]), description: LocalizedString(["en": n]),
                isActive: true, prices: try samplePrices(), features: sampleFeatures(),
                now: Date(timeIntervalSince1970: t)
            )
            await ds.seed(mapper.toModel(entity: plan))
        }
        return ds
    }

    @Test("list returns every plan, oldest first")
    func list() async throws {
        let ds = try await seeded()
        let handler = ListPlansQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper,
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
        let dtos = try await handler.handle(ListPlansQuery())
        #expect(dtos.map(\.SKU) == ["SKU-c", "SKU-b", "SKU-a"])
    }

    @Test("get returns the plan, or ApplicationError.notFound")
    func get() async throws {
        let ds = try await seeded()
        let id = try #require(try await ds.query(DataSourceQuery()).items.first?.id)
        let handler = GetPlanQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper,
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
        #expect(try await handler.handle(GetPlanQuery(planId: id)).id == id)
        await #expect(throws: ApplicationError.self) {
            try await handler.handle(GetPlanQuery(planId: "plan-missing"))
        }
    }
}
