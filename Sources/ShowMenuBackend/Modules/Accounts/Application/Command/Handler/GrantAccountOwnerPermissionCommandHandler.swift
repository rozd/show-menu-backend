import Foundation
import Logging

struct GrantAccountOwnerPermissionCommandHandler: InboxedCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<GrantAccountOwnerPermissionUseCase>
    let inbox: InboxComponents
    let logger: Logger

    func perform(_ command: GrantAccountOwnerPermissionCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling GrantAccountOwnerPermissionCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId)
        ])
        try await useCaseFactory(ctx).execute(params: .init(accountId: command.payload.accountId))
    }
}
