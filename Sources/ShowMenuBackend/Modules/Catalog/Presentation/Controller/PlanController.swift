import Vapor

/// Admin-only plan endpoints. Errors are thrown as typed errors and rendered by
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

    /// `POST /api/v1/plans` → 200 `PlanResponse` (Node answers 200, not 201).
    @Sendable
    func createPlan(req: Request) async throws -> PlanDTO {
        let payload = try req.content.decode(CreatePlanCommand.Payload.self)
        return try await createPlanCommandHandler.handle(CreatePlanCommand(
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }

    /// `GET /api/v1/plans/:id` → 200 `PlanResponse`; unknown id → 404.
    @Sendable
    func getPlan(req: Request) async throws -> PlanDTO {
        guard let planId = req.parameters.get("planId") else {
            throw Abort(.badRequest, reason: "Missing planId parameter")
        }
        return try await getPlanQueryHandler.handle(GetPlanQuery(planId: planId))
    }

    /// `GET /api/v1/plans` → 200 `[PlanResponse]`.
    @Sendable
    func listPlans(req: Request) async throws -> [PlanDTO] {
        try await listPlansQueryHandler.handle(ListPlansQuery())
    }

    private func planId(_ req: Request) throws -> String {
        guard let planId = req.parameters.get("planId") else {
            throw Abort(.badRequest, reason: "Missing planId parameter")
        }
        return planId
    }

    /// `PUT /api/v1/plans/:id` → 200 `PlanResponse`.
    @Sendable
    func updatePlan(req: Request) async throws -> PlanDTO {
        let payload = try req.content.decode(UpdatePlanCommand.Payload.self)
        return try await updatePlanCommandHandler.handle(UpdatePlanCommand(
            planId: try planId(req),
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }

    /// `PUT /api/v1/plans/:id/activate` → 200, empty body; idempotent.
    @Sendable
    func activatePlan(req: Request) async throws -> HTTPStatus {
        try await activatePlanCommandHandler.handle(ActivatePlanCommand(
            planId: try planId(req),
            metadata: CommandMetadata(req: req)
        ))
        return .ok
    }

    /// `PUT /api/v1/plans/:id/deactivate` → 200, empty body; idempotent.
    @Sendable
    func deactivatePlan(req: Request) async throws -> HTTPStatus {
        try await deactivatePlanCommandHandler.handle(DeactivatePlanCommand(
            planId: try planId(req),
            metadata: CommandMetadata(req: req)
        ))
        return .ok
    }

    /// `PUT /api/v1/plans/:id/features` → 200 `PlanResponse`.
    @Sendable
    func addFeature(req: Request) async throws -> PlanDTO {
        let payload = try req.content.decode(AddPlanFeatureCommand.Payload.self)
        return try await addPlanFeatureCommandHandler.handle(AddPlanFeatureCommand(
            planId: try planId(req),
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }

    /// `DELETE /api/v1/plans/:id/features/:featureId` → 200, empty body; 404 if the
    /// feature is not in the plan.
    @Sendable
    func removeFeature(req: Request) async throws -> HTTPStatus {
        guard let featureId = req.parameters.get("featureId") else {
            throw Abort(.badRequest, reason: "Missing featureId parameter")
        }
        try await removePlanFeatureCommandHandler.handle(RemovePlanFeatureCommand(
            planId: try planId(req),
            featureId: featureId,
            metadata: CommandMetadata(req: req)
        ))
        return .ok
    }
}
