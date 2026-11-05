import Foundation
import Logging

struct CreateUserAccountCommandHandler: InboxedCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UserOnboardUseCase>
    let inbox: InboxComponents
    let logger: Logger

    func perform(_ command: CreateUserAccountCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling CreateUserAccountCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        let useCase = useCaseFactory(ctx)
        try await useCase.execute(
            params: .init(
                userId: User.Id(rawValue: command.payload.userId),
                email: command.payload.email,
                name: command.payload.displayName,
                avatarURL: command.payload.photoURL
            )
        )
    }
}
