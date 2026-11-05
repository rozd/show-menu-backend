import Foundation
import Logging

/// Applies a LiqPay callback in one unit of work. Inboxed: a redelivered callback (same
/// `order_id`, `status`, `payment_id`) is skipped silently.
struct HandleLiqPayCallbackCommandHandler: InboxedCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<HandleLiqPayCallbackUseCase>
    let inbox: InboxComponents
    let logger: Logger

    func perform(_ command: HandleLiqPayCallbackCommand, in ctx: any UnitOfWorkContext) async throws -> Void {
        logger.info("Handling HandleLiqPayCallbackCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "orderId": .string(command.payload.orderId),
            "status": .string(command.payload.status)
        ])
        try await useCaseFactory(ctx).execute(params: .init(payload: command.payload))
    }
}
