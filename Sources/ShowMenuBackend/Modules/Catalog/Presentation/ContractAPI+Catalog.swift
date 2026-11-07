import ShowMenuContracts

/// Catalog's witnesses: the ten admin-only plan and feature operations.
extension ContractAPI {

    private var featureController: FeatureController {
        FeatureController(
            createFeatureCommandHandler: app.deps.createFeatureCommandHandler,
            updateFeatureCommandHandler: app.deps.updateFeatureCommandHandler
        )
    }

    private var planController: PlanController {
        PlanController(
            createPlanCommandHandler: app.deps.createPlanCommandHandler,
            getPlanQueryHandler: app.deps.getPlanQueryHandler,
            listPlansQueryHandler: app.deps.listPlansQueryHandler,
            updatePlanCommandHandler: app.deps.updatePlanCommandHandler,
            activatePlanCommandHandler: app.deps.activatePlanCommandHandler,
            deactivatePlanCommandHandler: app.deps.deactivatePlanCommandHandler,
            addPlanFeatureCommandHandler: app.deps.addPlanFeatureCommandHandler,
            removePlanFeatureCommandHandler: app.deps.removePlanFeatureCommandHandler
        )
    }

    func createFeature(_ input: Operations.CreateFeature.Input) async throws -> Operations.CreateFeature.Output {
        try await featureController.createFeature(input)
    }

    func updateFeature(_ input: Operations.UpdateFeature.Input) async throws -> Operations.UpdateFeature.Output {
        try await featureController.updateFeature(input)
    }

    func listPlans(_ input: Operations.ListPlans.Input) async throws -> Operations.ListPlans.Output {
        try await planController.listPlans(input)
    }

    func createPlan(_ input: Operations.CreatePlan.Input) async throws -> Operations.CreatePlan.Output {
        try await planController.createPlan(input)
    }

    func getPlan(_ input: Operations.GetPlan.Input) async throws -> Operations.GetPlan.Output {
        try await planController.getPlan(input)
    }

    func updatePlan(_ input: Operations.UpdatePlan.Input) async throws -> Operations.UpdatePlan.Output {
        try await planController.updatePlan(input)
    }

    func activatePlan(_ input: Operations.ActivatePlan.Input) async throws -> Operations.ActivatePlan.Output {
        try await planController.activatePlan(input)
    }

    func deactivatePlan(_ input: Operations.DeactivatePlan.Input) async throws -> Operations.DeactivatePlan.Output {
        try await planController.deactivatePlan(input)
    }

    func addPlanFeature(_ input: Operations.AddPlanFeature.Input) async throws -> Operations.AddPlanFeature.Output {
        try await planController.addPlanFeature(input)
    }

    func removePlanFeature(_ input: Operations.RemovePlanFeature.Input) async throws -> Operations.RemovePlanFeature.Output {
        try await planController.removePlanFeature(input)
    }
}
