import Foundation
import Logging

struct RemovePlanFeatureUseCase: UseCase {
    struct Params: Sendable {
        let planId: Plan.Id
        let featureId: Feature.Id
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any PlanRepository>
    let logger: Logger

    func execute(params: Params) async throws {
        logger.info("Executing RemovePlanFeatureUseCase", metadata: [
            "planId": .string(params.planId.rawValue),
            "featureId": .string(params.featureId.rawValue)
        ])
        let repository = repositoryFactory(context)
        guard let plan = try await repository.fetch(byId: params.planId) else {
            throw ApplicationError.notFound(entity: "Plan", id: params.planId)
        }
        try plan.removeFeature(params.featureId)
        try await repository.update(entity: plan)
    }
}
