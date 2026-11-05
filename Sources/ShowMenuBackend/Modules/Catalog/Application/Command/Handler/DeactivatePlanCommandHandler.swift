import Foundation
import Logging

struct DeactivatePlanCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<DeactivatePlanUseCase>
    let logger: Logger

    func perform(_ command: DeactivatePlanCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling DeactivatePlanCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "planId": .string(command.planId)
        ])
        try await useCaseFactory(ctx).execute(params: .init(planId: Plan.Id(rawValue: command.planId)))
    }
}
