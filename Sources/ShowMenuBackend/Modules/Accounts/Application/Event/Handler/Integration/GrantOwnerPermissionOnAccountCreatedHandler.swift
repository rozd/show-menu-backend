import Foundation
import Logging

/// Grants the creator the `owner` role when an account is created.
struct GrantOwnerPermissionOnAccountCreatedHandler: IntegrationEventHandler {
    typealias Event = AccountCreatedIntegrationEvent

    let commandHandler: GrantAccountOwnerPermissionCommandHandler
    let logger: Logger

    func handle(_ event: AccountCreatedIntegrationEvent) async throws {
        logger.info("Processing AccountCreatedIntegrationEvent (owner permission)", metadata: [
            "accountId": .string(event.accountId)
        ])
        try await commandHandler.handle(
            GrantAccountOwnerPermissionCommand(
                payload: .init(accountId: event.accountId),
                metadata: CommandMetadata(correlationId: event.metadata.correlationId ?? TraceID())
            )
        )
    }
}
