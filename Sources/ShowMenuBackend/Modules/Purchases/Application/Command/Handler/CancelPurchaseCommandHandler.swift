import Foundation
import Logging

/// Cancels a pending purchase in one unit of work. Naturally idempotent (a repeated cancel
/// is a 200 no-op, see ``CancelPurchaseUseCase``), so it does not need
/// `IdempotentCommandHandler`.
struct CancelPurchaseCommandHandler: CommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<CancelPurchaseUseCase>
    let logger: Logger

    func perform(_ command: CancelPurchaseCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling CancelPurchaseCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "accountId": .string(command.accountId),
            "invoiceId": .string(command.invoiceId)
        ])
        try await useCaseFactory(ctx).execute(params: .init(accountId: command.accountId, invoiceId: command.invoiceId))
    }
}
