import Foundation
import Logging

struct CreateItemCommandHandler: IdempotentCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<CreateItemUseCase>
    let idempotency: IdempotencyComponents
    let logger: Logger

    func perform(_ command: CreateItemCommand, in ctx: any UnitOfWorkContext) async throws -> ItemDTO {
        logger.info("Handling CreateItemCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        let useCase = useCaseFactory(ctx)
        return try await useCase.execute(
            params: .init(
                name: command.payload.name,
                description: command.payload.description
            )
        )
    }
}
