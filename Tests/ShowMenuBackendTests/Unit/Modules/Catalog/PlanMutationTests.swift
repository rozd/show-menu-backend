import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("Plan mutations")
struct PlanMutationTests {
    let mapper = PlanMapper()

    private func makeSUT(isActive: Bool = false, featureIds: [String] = ["feature-1"]) async throws -> (
        ds: InMemoryDataSource<PlanModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext,
        planId: Plan.Id
    ) {
        let ds = InMemoryDataSource<PlanModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        let ctx = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        let plan = try Plan.create(
            SKU: "SKU-1",
            name: LocalizedString(["en": "Pro"]),
            description: LocalizedString(["en": "Desc"]),
            isActive: isActive,
            prices: [PlanPrice(price: try Price(currency: Currency(name: "USD"), amount: 10), duration: .monthly)],
            features: featureIds.map {
                PlanFeature(featureId: .init(rawValue: $0), quota: FeatureQuota(unit: .count, limit: 5))
            },
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = plan.pullEvents()
        await ds.seed(mapper.toModel(entity: plan))
        return (ds, collector, ctx, plan.id)
    }

    private var repositoryFactory: (InMemoryDataSource<PlanModel>) -> RepositoryFactory<any PlanRepository> {
        { ds in
            let mapper = self.mapper
            return { ctx in
                FirestorePlanRepository(
                    mapper: mapper,
                    dataSourceFactory: { _, _ in ds },
                    skuDataSourceFactory: { _, _ in InMemoryDataSource<PlanSKUModel>(id: { $0.id }) },
                    context: ctx
                )
            }
        }
    }

    private func isPlanNotFound(_ error: any Error) -> Bool {
        if case ApplicationError.notFound(entity: "Plan", id: _) = error { return true }
        return false
    }

    private var logger: Logger { Logger(label: "test", factory: { _ in CapturingLogHandler() }) }

    private func stored(_ ds: InMemoryDataSource<PlanModel>, _ id: Plan.Id) async throws -> PlanModel {
        try #require(try await ds.fetch(byId: id.rawValue))
    }

    private func kinds(_ collector: InMemoryDomainEventCollector) async throws -> [PlanEventKind] {
        try await collector.drain().map { try #require($0 as? PlanEvent).kind }
    }

    // MARK: Update

    @Test("update replaces name and description, bumps updatedAt, returns the DTO")
    func update() async throws {
        let (ds, collector, ctx, id) = try await makeSUT()
        let useCase = UpdatePlanUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), mapper: mapper, logger: logger)
        let dto = try await useCase.execute(params: .init(
            planId: id, payload: .init(name: ["en": "New", "uk": "Нова"], description: ["en": "D2"])
        ))
        #expect(dto.name == ["en": "New", "uk": "Нова"])
        #expect(dto.description == ["en": "D2"])
        #expect(dto.SKU == "SKU-1")
        let model = try await stored(ds, id)
        #expect(model.name.values["en"] == "New")
        #expect(model.updatedAt.asDate > model.createdAt.asDate)
        #expect(try await kinds(collector) == [.updated])
    }

    @Test("update: missing or blank name/description → 422; unknown plan → 404")
    func updateErrors() async throws {
        let (ds, _, ctx, id) = try await makeSUT()
        let useCase = UpdatePlanUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), mapper: mapper, logger: logger)
        await #expect(throws: Plan.Error.nameRequired) {
            try await useCase.execute(params: .init(planId: id, payload: .init(name: nil, description: ["en": "x"])))
        }
        await #expect(throws: Plan.Error.descriptionRequired) {
            try await useCase.execute(params: .init(planId: id, payload: .init(name: ["en": "x"], description: nil)))
        }
        await #expect(throws: (any Error).self) {
            try await useCase.execute(params: .init(planId: id, payload: .init(name: [:], description: ["en": "x"])))
        }
        await #expect {
            try await useCase.execute(params: .init(
                planId: .init(rawValue: "plan-missing"), payload: .init(name: ["en": "x"], description: ["en": "x"])
            ))
        } throws: { isPlanNotFound($0) }
    }

    // MARK: Activate / deactivate

    @Test("activate flips isActive and records semantic + lifecycle events")
    func activate() async throws {
        let (ds, collector, ctx, id) = try await makeSUT()
        let useCase = ActivatePlanUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
        try await useCase.execute(params: .init(planId: id))
        #expect(try await stored(ds, id).isActive)
        #expect(try await kinds(collector) == [.planActivated, .updated])
    }

    @Test("activate and deactivate are idempotent: state and updatedAt unchanged, no semantic event")
    func idempotent() async throws {
        let (ds, collector, ctx, id) = try await makeSUT(isActive: true)
        let before = try await stored(ds, id)
        try await ActivatePlanUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
            .execute(params: .init(planId: id))
        #expect(try await stored(ds, id).isActive)
        #expect(try await stored(ds, id).updatedAt == before.updatedAt)
        #expect(try await kinds(collector) == [.updated]) // persisted, but no semantic event

        let (ds2, collector2, ctx2, id2) = try await makeSUT(isActive: false)
        try await DeactivatePlanUseCase(context: ctx2, repositoryFactory: repositoryFactory(ds2), logger: logger)
            .execute(params: .init(planId: id2))
        #expect(try await stored(ds2, id2).isActive == false)
        #expect(try await kinds(collector2) == [.updated])
    }

    @Test("deactivate flips isActive; unknown plan → 404")
    func deactivate() async throws {
        let (ds, collector, ctx, id) = try await makeSUT(isActive: true)
        let useCase = DeactivatePlanUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
        try await useCase.execute(params: .init(planId: id))
        #expect(try await stored(ds, id).isActive == false)
        #expect(try await kinds(collector) == [.planDeactivated, .updated])
        await #expect {
            try await useCase.execute(params: .init(planId: .init(rawValue: "plan-missing")))
        } throws: { isPlanNotFound($0) }
    }

    // MARK: Features

    private func addUseCase(_ ds: InMemoryDataSource<PlanModel>, _ ctx: StubUnitOfWorkContext) -> AddPlanFeatureUseCase {
        AddPlanFeatureUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), mapper: mapper, logger: logger)
    }

    @Test("add feature: appended, DTO returned, semantic plan.feature.added recorded")
    func addFeature() async throws {
        let (ds, collector, ctx, id) = try await makeSUT()
        let dto = try await addUseCase(ds, ctx).execute(params: .init(
            planId: id, input: .init(featureId: "feature-2", quota: .init(unit: "level", limit: 3))
        ))
        #expect(dto.features.map(\.featureId) == ["feature-1", "feature-2"])
        #expect(try await stored(ds, id).features.count == 2)
        #expect(try await kinds(collector) == [.planFeatureAdded, .updated])
    }

    @Test("add feature: duplicate id, bad unit and missing quota are 422; plan is left untouched")
    func addFeatureErrors() async throws {
        let (ds, _, ctx, id) = try await makeSUT()
        let useCase = addUseCase(ds, ctx)
        await #expect(throws: Plan.Error.duplicateFeatures) {
            try await useCase.execute(params: .init(
                planId: id, input: .init(featureId: "feature-1", quota: .init(unit: "count", limit: 1))
            ))
        }
        await #expect(throws: Plan.Error.invalidQuotaUnit("bogus")) {
            try await useCase.execute(params: .init(
                planId: id, input: .init(featureId: "feature-2", quota: .init(unit: "bogus", limit: 1))
            ))
        }
        await #expect(throws: Plan.Error.quotaRequired) {
            try await useCase.execute(params: .init(planId: id, input: .init(featureId: "feature-2", quota: nil)))
        }
        await #expect(throws: Plan.Error.featureIdRequired) {
            try await useCase.execute(params: .init(planId: id, input: .init(featureId: nil, quota: nil)))
        }
        await #expect {
            try await useCase.execute(params: .init(
                planId: .init(rawValue: "plan-missing"),
                input: .init(featureId: "feature-2", quota: .init(unit: "count", limit: 1))
            ))
        } throws: { isPlanNotFound($0) }
        #expect(try await stored(ds, id).features.count == 1)
        #expect(await ds.updatedModels.isEmpty)
    }

    @Test("remove feature emits plan.feature.removed, never plan.feature.added (bug 7)")
    func removeFeature() async throws {
        let (ds, collector, ctx, id) = try await makeSUT(featureIds: ["feature-1", "feature-2"])
        let useCase = RemovePlanFeatureUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
        try await useCase.execute(params: .init(planId: id, featureId: .init(rawValue: "feature-1")))
        #expect(try await stored(ds, id).features.map(\.featureId.rawValue) == ["feature-2"])
        let recorded = try await kinds(collector)
        #expect(recorded == [.planFeatureRemoved, .updated])
        #expect(!recorded.contains(.planFeatureAdded))
    }

    @Test("remove feature: absent feature → PlanFeatureNotFoundError (404), unknown plan → 404")
    func removeAbsent() async throws {
        let (ds, _, ctx, id) = try await makeSUT()
        let useCase = RemovePlanFeatureUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
        let missing = Feature.Id(rawValue: "feature-x")
        await #expect(throws: PlanFeatureNotFoundError(planId: id, featureId: missing)) {
            try await useCase.execute(params: .init(planId: id, featureId: missing))
        }
        #expect(PlanFeatureNotFoundError(planId: id, featureId: missing).httpStatusHint == .notFound)
        await #expect {
            try await useCase.execute(params: .init(planId: .init(rawValue: "plan-missing"), featureId: missing))
        } throws: { isPlanNotFound($0) }
    }

    @Test("removing the last feature is rejected (422, invariant) and nothing is written")
    func removeLastFeature() async throws {
        let (ds, collector, ctx, id) = try await makeSUT()
        let useCase = RemovePlanFeatureUseCase(context: ctx, repositoryFactory: repositoryFactory(ds), logger: logger)
        await #expect(throws: Plan.Error.featuresRequired) {
            try await useCase.execute(params: .init(planId: id, featureId: .init(rawValue: "feature-1")))
        }
        #expect(Plan.Error.featuresRequired is any ValidationError)
        #expect(try await stored(ds, id).features.count == 1)
        #expect(await ds.updatedModels.isEmpty)
        #expect(try await kinds(collector).isEmpty)
    }
}
