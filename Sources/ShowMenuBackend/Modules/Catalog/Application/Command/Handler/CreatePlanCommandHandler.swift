import Foundation
import Logging

struct CreatePlanCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<CreatePlanUseCase>
    let logger: Logger

    func perform(_ command: CreatePlanCommand, in ctx: any UnitOfWorkContext) async throws -> PlanDTO {
        logger.info("Handling CreatePlanCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        return try await useCaseFactory(ctx).execute(params: .init(payload: command.payload))
    }
}
