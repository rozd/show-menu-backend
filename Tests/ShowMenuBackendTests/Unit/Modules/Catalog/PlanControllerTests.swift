import Foundation
import Logging
import OpenAPIRuntime
import ShowMenuContracts
import Testing
@testable import ShowMenuBackend

/// The Catalog controller against generated `Input` / `Output` types, with in-memory
/// persistence: wire fidelity (SKU key, ISO dates with milliseconds, omitted-when-absent
/// currency parts) and error propagation.
@Suite("Catalog controllers (wire)")
struct PlanControllerTests {

    private let mapper = PlanMapper()
    private var logger: Logger { Logger(label: "test", factory: { _ in CapturingLogHandler() }) }

    private func makeController(_ ds: InMemoryDataSource<PlanModel>) -> PlanController {
        let mapper = self.mapper
        let logger = self.logger
        let uow = StubUnitOfWork()
        let repositoryFactory: RepositoryFactory<any PlanRepository> = { ctx in
            FirestorePlanRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                skuDataSourceFactory: { _, _ in InMemoryDataSource<PlanSKUModel>(id: { $0.id }) },
                context: ctx
            )
        }
        return PlanController(
            createPlanCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { CreatePlanUseCase(context: $0, repositoryFactory: repositoryFactory, mapper: mapper, logger: logger) },
                logger: logger
            ),
            getPlanQueryHandler: .init(dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger),
            listPlansQueryHandler: .init(dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger),
            updatePlanCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { UpdatePlanUseCase(context: $0, repositoryFactory: repositoryFactory, mapper: mapper, logger: logger) },
                logger: logger
            ),
            activatePlanCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { ActivatePlanUseCase(context: $0, repositoryFactory: repositoryFactory, logger: logger) },
                logger: logger
            ),
            deactivatePlanCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { DeactivatePlanUseCase(context: $0, repositoryFactory: repositoryFactory, logger: logger) },
                logger: logger
            ),
            addPlanFeatureCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { AddPlanFeatureUseCase(context: $0, repositoryFactory: repositoryFactory, mapper: mapper, logger: logger) },
                logger: logger
            ),
            removePlanFeatureCommandHandler: .init(
                unitOfWork: uow,
                useCaseFactory: { RemovePlanFeatureUseCase(context: $0, repositoryFactory: repositoryFactory, logger: logger) },
                logger: logger
            )
        )
    }

    private func createRequest() -> Components.Schemas.CreatePlanRequest {
        .init(
            sku: "PRO",
            name: .init(additionalProperties: ["en": "Pro", "uk": "Про"]),
            description: .init(additionalProperties: ["en": "Pro plan"]),
            isActive: true,
            prices: [.init(price: .init(currencyName: "USD", amount: 9.99), duration: .monthly)],
            features: [.init(featureId: "feature-1", quota: .init(unit: .count, limit: 100))]
        )
    }

    private func plan(from output: Operations.CreatePlan.Output) throws -> Components.Schemas.Plan {
        guard case let .ok(ok) = output, case let .json(plan) = ok.body else {
            Issue.record("Expected 200 JSON")
            throw CancellationError()
        }
        return plan
    }

    @Test("createPlan returns the wire Plan: SKU, a real Date, Currency parts omitted when absent")
    func createPlan() async throws {
        let controller = makeController(InMemoryDataSource<PlanModel>(id: { $0.id }))
        let before = Date().addingTimeInterval(-1)

        let output = try await controller.createPlan(.init(body: .json(createRequest())))
        let plan = try plan(from: output)

        #expect(plan.sku == "PRO")
        #expect(plan.isActive)
        #expect(plan.name.additionalProperties == ["en": "Pro", "uk": "Про"])
        #expect(plan.createdAt >= before && plan.createdAt <= Date().addingTimeInterval(1))
        #expect(plan.prices.first?.duration == .monthly)
        #expect(plan.prices.first?.price.amount == 9.99)
        #expect(plan.features.first?.quota.unit == .count)
        #expect(plan.features.first?.quota.limit == 100)

        // Currency: only `name` was supplied, so symbol/base/digits are absent (not null).
        let currency = try #require(plan.prices.first?.price.currency)
        #expect(currency.name == "USD" && currency.symbol == nil && currency.base == nil && currency.digits == nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currency)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["name"])
    }

    @Test("createPlan surfaces domain failures as thrown errors (duplicate prices → 422 mapping)")
    func createPlanThrows() async throws {
        let controller = makeController(InMemoryDataSource<PlanModel>(id: { $0.id }))
        var request = createRequest()
        request.prices.append(request.prices[0])
        await #expect(throws: (any Error).self) {
            _ = try await controller.createPlan(.init(body: .json(request)))
        }
    }

    @Test("getPlan returns the created plan; an unknown id throws not_found")
    func getPlan() async throws {
        let controller = makeController(InMemoryDataSource<PlanModel>(id: { $0.id }))
        let created = try plan(from: try await controller.createPlan(.init(body: .json(createRequest()))))

        let output = try await controller.getPlan(.init(path: .init(planId: created.id)))
        guard case let .ok(ok) = output, case let .json(plan) = ok.body else {
            Issue.record("Expected 200 JSON")
            return
        }
        #expect(plan.id == created.id && plan.sku == "PRO")

        do {
            _ = try await controller.getPlan(.init(path: .init(planId: "plan-missing")))
            Issue.record("expected not found")
        } catch {
            #expect(HTTPErrorMapping.map(error).code == "not_found")
        }
    }

    @Test("listPlans answers a bare array")
    func listPlans() async throws {
        let controller = makeController(InMemoryDataSource<PlanModel>(id: { $0.id }))
        _ = try await controller.createPlan(.init(body: .json(createRequest())))
        guard case let .ok(ok) = try await controller.listPlans(.init()), case let .json(plans) = ok.body else {
            Issue.record("Expected 200 JSON")
            return
        }
        #expect(plans.map(\.sku) == ["PRO"])
    }

    @Test("activate / deactivate answer 200 without a body")
    func activateDeactivate() async throws {
        let controller = makeController(InMemoryDataSource<PlanModel>(id: { $0.id }))
        let created = try plan(from: try await controller.createPlan(.init(body: .json(createRequest()))))
        guard case .ok = try await controller.deactivatePlan(.init(path: .init(planId: created.id))) else {
            Issue.record("Expected 200")
            return
        }
        guard case .ok = try await controller.activatePlan(.init(path: .init(planId: created.id))) else {
            Issue.record("Expected 200")
            return
        }
    }

    // MARK: Wire mapping

    @Test("Date.parseISO reads JS toISOString (milliseconds) and second-precision strings")
    func dateParsing() throws {
        let millis = try #require(Date.parseISO("2025-01-15T10:00:00.123Z"))
        #expect(millis.timeIntervalSince1970 == 1_736_935_200.123)
        let whole = try #require(Date.parseISO("2025-01-15T10:00:00Z"))
        #expect(whole.timeIntervalSince1970 == 1_736_935_200)
        #expect(Date.parseISO("yesterday") == nil)
        #expect(throws: InvalidDateStringError.self) { _ = try Date.parseISOOrThrow("yesterday") }
        // Round trip through the producer used by the DTO mappers.
        #expect(Date.parseISO(millis.jsISOString) == millis)
    }

    @Test("a stored value the wire cannot express is a data fault (thrown), not a client error")
    func wireDataFaults() throws {
        let dto = PlanDTO(
            id: "p", createdAt: "not-a-date", updatedAt: "2025-01-15T10:00:00.000Z", SKU: "S",
            name: ["en": "n"], description: ["en": "d"], isActive: true, prices: [], features: []
        )
        #expect(throws: InvalidDateStringError.self) { _ = try CatalogWireMapper.wire(dto) }
        let feature = FeatureDTO(
            id: "f", createdAt: "2025-01-15T10:00:00.000Z", updatedAt: "2025-01-15T10:00:00.000Z",
            category: "mystery", name: ["en": "n"], description: nil
        )
        #expect(throws: (any Error).self) { _ = try CatalogWireMapper.wire(feature) }
        #expect(HTTPErrorMapping.map(InvalidDateStringError(value: "x")).status == .internalServerError)
    }

    @Test("a feature without description omits it on the wire")
    func featureDescriptionOmitted() throws {
        let dto = FeatureDTO(
            id: "f", createdAt: "2025-01-15T10:00:00.000Z", updatedAt: "2025-01-15T10:00:00.000Z",
            category: "ai", name: ["en": "AI"], description: nil
        )
        let wire = try CatalogWireMapper.wire(dto)
        #expect(wire.description == nil && wire.category == .ai)
    }
}
