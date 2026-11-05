import Foundation
import Logging

struct CreateFeatureCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<CreateFeatureUseCase>
    let logger: Logger

    func perform(_ command: CreateFeatureCommand, in ctx: any UnitOfWorkContext) async throws -> FeatureDTO {
        logger.info("Handling CreateFeatureCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        let useCase = useCaseFactory(ctx)
        return try await useCase.execute(
            params: .init(
                category: command.payload.category,
                name: command.payload.name,
                description: command.payload.description
            )
        )
    }
}
