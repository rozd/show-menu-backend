import Foundation
import Logging

struct DeleteUserAccountCommandHandler: InboxedCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UserRemoveUseCase>
    let inbox: InboxComponents
    let logger: Logger

    func perform(_ command: DeleteUserAccountCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling DeleteUserAccountCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        let useCase = useCaseFactory(ctx)
        try await useCase.execute(
            params: .init(
                userId: User.Id(rawValue: command.payload.userId)
            )
        )
    }
}
