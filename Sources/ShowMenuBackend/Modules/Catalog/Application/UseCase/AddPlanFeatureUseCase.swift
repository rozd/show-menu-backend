import Foundation
import Logging

struct AddPlanFeatureUseCase: UseCase {
    struct Params: Sendable {
        let planId: Plan.Id
        let input: CreatePlanCommand.FeatureInput
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any PlanRepository>
    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let logger: Logger

    func execute(params: Params) async throws -> PlanDTO {
        logger.info("Executing AddPlanFeatureUseCase", metadata: ["planId": .string(params.planId.rawValue)])
        let feature = try params.input.toPlanFeature()

        let repository = repositoryFactory(context)
        guard let plan = try await repository.fetch(byId: params.planId) else {
            throw ApplicationError.notFound(entity: "Plan", id: params.planId)
        }
        // Node did not check that the feature exists in `features/` (parity); only
        // the plan invariants (unique featureIds) are enforced.
        try plan.addFeature(feature)
        try await repository.update(entity: plan)
        return mapper.toDTO(entity: plan)
    }
}
