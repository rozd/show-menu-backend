import Foundation

/// Integration event published when a Firebase Auth user is created.
///
/// Published by `EventarcController.handleUserCreated()` upon receiving
/// a `google.firebase.auth.user.v1.created` CloudEvent forwarded by the
/// auth-forwarder Cloud Function. Consumed by `UserCreatedIntegrationEventHandler`.
struct UserCreatedIntegrationEvent: IntegrationEvent {
    static let kind: String = "users.created"

    let id: UUID
    let metadata: IntegrationEventMetadata

    let userId: String
    let email: String?
    let displayName: String?
    /// Optional: events recorded before this field existed decode with `nil`.
    let photoURL: String?
    let registeredAt: Date

    init(
        id: UUID = UUID(),
        userId: String,
        email: String?,
        displayName: String?,
        photoURL: String? = nil,
        registeredAt: Date = .now,
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
        self.photoURL = photoURL
        self.registeredAt = registeredAt
    }
}
