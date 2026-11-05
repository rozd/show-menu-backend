import Foundation
import Logging

struct RemovePlanFeatureCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<RemovePlanFeatureUseCase>
    let logger: Logger

    func perform(_ command: RemovePlanFeatureCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling RemovePlanFeatureCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "planId": .string(command.planId)
        ])
        try await useCaseFactory(ctx).execute(params: .init(
            planId: Plan.Id(rawValue: command.planId),
            featureId: Feature.Id(rawValue: command.featureId)
        ))
    }
}
