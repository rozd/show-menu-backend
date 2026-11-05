import Foundation
import Logging

struct ActivatePlanCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<ActivatePlanUseCase>
    let logger: Logger

    func perform(_ command: ActivatePlanCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling ActivatePlanCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "planId": .string(command.planId)
        ])
        try await useCaseFactory(ctx).execute(params: .init(planId: Plan.Id(rawValue: command.planId)))
    }
}
