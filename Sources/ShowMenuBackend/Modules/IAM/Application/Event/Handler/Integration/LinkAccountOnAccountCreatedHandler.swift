import Foundation
import Logging

/// Links a newly created account to its creator (`users/{uid}.accounts`).
struct LinkAccountOnAccountCreatedHandler: IntegrationEventHandler {
    typealias Event = AccountCreatedIntegrationEvent

    let commandHandler: LinkAccountToCreatorCommandHandler
    let logger: Logger

    func handle(_ event: AccountCreatedIntegrationEvent) async throws {
        logger.info("Processing AccountCreatedIntegrationEvent (link to creator)", metadata: [
            "accountId": .string(event.accountId),
            "creatorId": .string(event.creatorId)
        ])
        try await commandHandler.handle(
            LinkAccountToCreatorCommand(
                payload: .init(accountId: event.accountId, creatorId: event.creatorId),
                metadata: CommandMetadata(correlationId: event.metadata.correlationId ?? TraceID())
            )
        )
    }
}
