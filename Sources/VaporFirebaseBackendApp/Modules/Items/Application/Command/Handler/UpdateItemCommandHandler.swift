import Foundation
import Logging

struct UpdateItemCommandHandler: IdempotentCommandHandler {
    let unitOfWork: any UnitOfWork
    let useCaseFactory: UseCaseFactory<UpdateItemUseCase>
    let idempotency: IdempotencyComponents
    let logger: Logger

    func perform(_ command: UpdateItemCommand, in ctx: any UnitOfWorkContext) async throws -> ItemDTO {
        logger.info("Handling UpdateItemCommand", metadata: [
            "correlationId": .stringConvertible(command.metadata.correlationId),
            "itemId": .string(command.itemId)
        ])
        let useCase = useCaseFactory(ctx)
        return try await useCase.execute(
            params: .init(
                itemId: Item.Id(rawValue: command.itemId),
                expectedEntityVersion: command.expectedEntityVersion,
                name: command.payload.name,
                description: command.payload.description
            )
        )
    }

    /// `itemId` is a route parameter that lives outside `payload`, so the default
    /// (payload-only) fingerprint would let the same key replay across *different*
    /// items. Fold it in so a key reused against a different item is rejected as a
    /// fingerprintMismatch instead of silently replaying the first item's response.
    func fingerprint(for command: UpdateItemCommand) throws -> RequestFingerprint {
        try RequestFingerprint(payload: FingerprintScope(
            itemId: command.itemId,
            payload: command.payload
        ))
    }

    /// Canonical scope folding the route parameter into the payload for fingerprinting.
    private struct FingerprintScope: Encodable {
        let itemId: String
        let payload: UpdateItemCommand.Payload
    }
}
