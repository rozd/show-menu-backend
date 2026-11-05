import Foundation
import Logging

/// Integration event handler that removes the local `User` record when
/// `UserDeletedIntegrationEvent` is received from Firebase Auth.
struct UserDeletedIntegrationEventHandler: IntegrationEventHandler {
    typealias Event = UserDeletedIntegrationEvent

    let commandHandler: DeleteUserAccountCommandHandler
    let logger: Logger

    func handle(_ event: UserDeletedIntegrationEvent) async throws {
        logger.info("Processing UserDeletedIntegrationEvent", metadata: [
            "userId": .string(event.userId),
            "email": .string(event.email ?? "(not provided)")
        ])

        let command = DeleteUserAccountCommand(
            payload: .init(userId: event.userId),
            metadata: CommandMetadata(
                correlationId: event.metadata.correlationId ?? TraceID()
            )
        )

        // This removal is initiated by the platform (mirroring a Firebase Auth
        // deletion), not an end user — run it as the trusted system principal so
        // the authorization PEP in UserRemoveUseCase passes via the normal rule.
        try await RequestContext.$principal.withValue(SystemPrincipal()) {
            try await commandHandler.handle(command)
        }
    }
}
