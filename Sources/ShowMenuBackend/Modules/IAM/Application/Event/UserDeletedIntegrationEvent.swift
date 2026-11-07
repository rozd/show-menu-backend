import Foundation

/// Integration event published when a Firebase Auth user is deleted.
///
/// Published by `EventarcController.handleUserDeleted()` upon receiving
/// a `google.firebase.auth.user.v1.deleted` CloudEvent forwarded by the
/// auth-forwarder Cloud Function. Consumed by `UserDeletedIntegrationEventHandler`.
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
