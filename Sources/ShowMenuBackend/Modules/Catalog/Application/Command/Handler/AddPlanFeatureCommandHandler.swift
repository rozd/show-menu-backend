import Foundation
import Logging

struct AddPlanFeatureCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<AddPlanFeatureUseCase>
    let logger: Logger

    func perform(_ command: AddPlanFeatureCommand, in ctx: any UnitOfWorkContext) async throws -> PlanDTO {
        logger.info("Handling AddPlanFeatureCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "planId": .string(command.planId)
        ])
        return try await useCaseFactory(ctx).execute(params: .init(planId: Plan.Id(rawValue: command.planId), input: command.payload))
    }
}
