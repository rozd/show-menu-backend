import Foundation
import Logging

struct UpdatePlanUseCase: UseCase {
    struct Params: Sendable {
        let planId: Plan.Id
        let payload: UpdatePlanCommand.Payload
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any PlanRepository>
    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let logger: Logger

    func execute(params: Params) async throws -> PlanDTO {
        logger.info("Executing UpdatePlanUseCase", metadata: ["planId": .string(params.planId.rawValue)])
        guard let rawName = params.payload.name else { throw Plan.Error.nameRequired }
        guard let rawDescription = params.payload.description else { throw Plan.Error.descriptionRequired }
        let name = try LocalizedString(rawName)
        let description = try LocalizedString(rawDescription)

        let repository = repositoryFactory(context)
        guard let plan = try await repository.fetch(byId: params.planId) else {
            throw ApplicationError.notFound(entity: "Plan", id: params.planId)
        }
        plan.update(name: name, description: description)
        try await repository.update(entity: plan)
        return mapper.toDTO(entity: plan)
    }
}
