import Foundation
import Logging

struct LinkAccountToCreatorCommandHandler: InboxedCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UserLinkAccountUseCase>
    let inbox: InboxComponents
    let logger: Logger

    func perform(_ command: LinkAccountToCreatorCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling LinkAccountToCreatorCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        try await useCaseFactory(ctx).execute(
            params: .init(accountId: command.payload.accountId)
        )
    }
}
