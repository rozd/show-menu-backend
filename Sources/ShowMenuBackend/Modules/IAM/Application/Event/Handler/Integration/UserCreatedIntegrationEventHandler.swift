import Foundation
import Logging

/// Integration event handler that creates a local `User` record when
/// `UserCreatedIntegrationEvent` is received from Firebase Auth.
///
/// Naming pattern: `{Action}On{IntegrationEvent}Handler` — here, the action
/// (`UserCreated`) and event share the lifecycle name, so this is collapsed
/// to `UserCreatedIntegrationEventHandler`.
struct UserCreatedIntegrationEventHandler: IntegrationEventHandler {
    typealias Event = UserCreatedIntegrationEvent

    let commandHandler: CreateUserAccountCommandHandler
    let logger: Logger

    func handle(_ event: UserCreatedIntegrationEvent) async throws {
        logger.info("Processing UserCreatedIntegrationEvent", metadata: [
            "userId": .string(event.userId),
            "email": .string(event.email ?? "(not provided)")
        ])

        let command = CreateUserAccountCommand(
            payload: .init(
                userId: event.userId,
                email: event.email,
                displayName: event.displayName
            ),
            metadata: CommandMetadata(
                correlationId: event.metadata.correlationId ?? TraceID()
            )
        )

        try await commandHandler.handle(command)
    }
}
