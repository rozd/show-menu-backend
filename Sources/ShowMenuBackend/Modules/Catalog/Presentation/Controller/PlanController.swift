import Vapor

/// Admin-only plan endpoints. Errors are thrown as typed errors and rendered by
/// `HTTPErrorMiddleware` (`Plan.Error` → 422, `PlanSKUAlreadyExistsError` → 409,
/// `ApplicationError.notFound` → 404).
struct PlanController: Sendable {

    let createPlanCommandHandler: CreatePlanCommandHandler
    let getPlanQueryHandler: GetPlanQueryHandler
    let listPlansQueryHandler: ListPlansQueryHandler

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
}
