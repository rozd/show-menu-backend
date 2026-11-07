import ShowMenuContracts
import Vapor

/// Admin-only plan operations. Errors are thrown as typed errors and rendered by
/// `HTTPErrorMiddleware` (`Plan.Error` → 422, `PlanSKUAlreadyExistsError` → 409,
/// `ApplicationError.notFound` → 404).
struct PlanController: Sendable {

    let createPlanCommandHandler: CreatePlanCommandHandler
    let getPlanQueryHandler: GetPlanQueryHandler
    let listPlansQueryHandler: ListPlansQueryHandler
    let updatePlanCommandHandler: UpdatePlanCommandHandler
    let activatePlanCommandHandler: ActivatePlanCommandHandler
    let deactivatePlanCommandHandler: DeactivatePlanCommandHandler
    let addPlanFeatureCommandHandler: AddPlanFeatureCommandHandler
    let removePlanFeatureCommandHandler: RemovePlanFeatureCommandHandler

    /// `createPlan` → 200 `Plan` (Node answers 200, not 201).
    func createPlan(_ input: Operations.CreatePlan.Input) async throws -> Operations.CreatePlan.Output {
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let dto = try await createPlanCommandHandler.handle(CreatePlanCommand(
            payload: CatalogWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }

    /// `getPlan` → 200 `Plan`; unknown id → 404.
    func getPlan(_ input: Operations.GetPlan.Input) async throws -> Operations.GetPlan.Output {
        let dto = try await getPlanQueryHandler.handle(GetPlanQuery(planId: input.path.planId))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }

    /// `listPlans` → 200 `[Plan]` (a bare array).
    func listPlans(_ input: Operations.ListPlans.Input) async throws -> Operations.ListPlans.Output {
        let dtos = try await listPlansQueryHandler.handle(ListPlansQuery())
        return .ok(.init(body: .json(try dtos.map(CatalogWireMapper.wire))))
    }

    /// `updatePlan` → 200 `Plan`.
    func updatePlan(_ input: Operations.UpdatePlan.Input) async throws -> Operations.UpdatePlan.Output {
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let dto = try await updatePlanCommandHandler.handle(UpdatePlanCommand(
            planId: input.path.planId,
            payload: CatalogWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }

    /// `activatePlan` → 200, empty body; idempotent.
    func activatePlan(_ input: Operations.ActivatePlan.Input) async throws -> Operations.ActivatePlan.Output {
        try await activatePlanCommandHandler.handle(ActivatePlanCommand(
            planId: input.path.planId,
            metadata: CommandMetadata()
        ))
        return .ok(.init())
    }

    /// `deactivatePlan` → 200, empty body; idempotent.
    func deactivatePlan(_ input: Operations.DeactivatePlan.Input) async throws -> Operations.DeactivatePlan.Output {
        try await deactivatePlanCommandHandler.handle(DeactivatePlanCommand(
            planId: input.path.planId,
            metadata: CommandMetadata()
        ))
        return .ok(.init())
    }

    /// `addPlanFeature` → 200 `Plan`.
    func addPlanFeature(_ input: Operations.AddPlanFeature.Input) async throws -> Operations.AddPlanFeature.Output {
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let dto = try await addPlanFeatureCommandHandler.handle(AddPlanFeatureCommand(
            planId: input.path.planId,
            payload: CatalogWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }

    /// `removePlanFeature` → 200, empty body; 404 if the feature is not in the plan.
    func removePlanFeature(_ input: Operations.RemovePlanFeature.Input) async throws -> Operations.RemovePlanFeature.Output {
        try await removePlanFeatureCommandHandler.handle(RemovePlanFeatureCommand(
            planId: input.path.planId,
            featureId: input.path.featureId,
            metadata: CommandMetadata()
        ))
        return .ok(.init())
    }
}
