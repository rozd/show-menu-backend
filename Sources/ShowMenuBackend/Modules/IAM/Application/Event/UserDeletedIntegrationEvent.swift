import Foundation

/// Integration event announcing that a user account was removed upstream.
///
/// Consumed by `UserDeletedIntegrationEventHandler`, which removes the local
/// `User` record. As with `UserCreatedIntegrationEvent`, it originates
/// **in-process** in this template; a real deployment would receive it from the
/// owning service over a message bus.
struct UserDeletedIntegrationEvent: IntegrationEvent {
    static let kind: String = "users.deleted"

    let id: UUID
    let metadata: IntegrationEventMetadata

    let userId: String
    let email: String?
    let displayName: String?
    let deletedAt: Date

    init(
        id: UUID = UUID(),
        userId: String,
        email: String?,
        displayName: String?,
        deletedAt: Date = .now,
        correlationId: TraceID? = nil
    ) {
        self.id = id
        self.metadata = IntegrationEventMetadata(
            origin: "IAM",
            correlationId: correlationId,
            occurredAt: .now
        )
        self.userId = userId
        self.email = email
        self.displayName = displayName
        self.deletedAt = deletedAt
    }
}
