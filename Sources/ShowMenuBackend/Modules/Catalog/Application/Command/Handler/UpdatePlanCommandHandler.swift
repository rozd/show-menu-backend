import Foundation
import Logging

struct UpdatePlanCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UpdatePlanUseCase>
    let logger: Logger

    func perform(_ command: UpdatePlanCommand, in ctx: any UnitOfWorkContext) async throws -> PlanDTO {
        logger.info("Handling UpdatePlanCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "planId": .string(command.planId)
        ])
        return try await useCaseFactory(ctx).execute(params: .init(planId: Plan.Id(rawValue: command.planId), payload: command.payload))
    }
}
