import Foundation
import Logging

struct UpdateFeatureCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UpdateFeatureUseCase>
    let logger: Logger

    func perform(_ command: UpdateFeatureCommand, in ctx: any UnitOfWorkContext) async throws -> FeatureDTO {
        logger.info("Handling UpdateFeatureCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "featureId": .string(command.featureId)
        ])
        let useCase = useCaseFactory(ctx)
        return try await useCase.execute(
            params: .init(
                featureId: Feature.Id(rawValue: command.featureId),
                category: command.payload.category,
                name: command.payload.name,
                description: command.payload.description
            )
        )
    }
}
