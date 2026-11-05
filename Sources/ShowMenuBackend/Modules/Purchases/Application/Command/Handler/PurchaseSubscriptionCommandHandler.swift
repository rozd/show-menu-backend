import Foundation
import Logging

/// Places the order, invoice and pending session in one transaction. Idempotent: with an
/// `Idempotency-Key` a retry replays the first invoice id; without one it is a plain
/// pass-through (see ``IdempotentCommandHandler``). The gateway checkout that follows is
/// ``CheckoutInitiator``'s job (post-commit), orchestrated by ``PurchaseSubscriptionFlow``.
struct PurchaseSubscriptionCommandHandler: IdempotentCommandHandler {
    typealias Params = PurchaseSubscriptionCommand
    typealias Result = String

    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<PurchaseSubscriptionUseCase>
    let idempotency: IdempotencyComponents
    let logger: Logger

    func perform(_ command: PurchaseSubscriptionCommand, in ctx: any UnitOfWorkContext) async throws -> String {
        logger.info("Handling PurchaseSubscriptionCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "accountId": .string(command.accountId)
        ])
        return try await useCaseFactory(ctx).execute(params: .init(
            accountId: command.accountId,
            customerEmail: command.customerEmail,
            payload: command.payload
        ))
    }

    /// The account comes from the route, not the payload: fold it in, so the same key and
    /// body against another account is a clean 422 instead of a replay of the wrong invoice.
    func fingerprint(for command: PurchaseSubscriptionCommand) throws -> RequestFingerprint {
        struct Scope: Encodable {
            let accountId: String
            let payload: PurchaseSubscriptionCommand.Payload
        }
        return try RequestFingerprint(payload: Scope(accountId: command.accountId, payload: command.payload))
    }
}
