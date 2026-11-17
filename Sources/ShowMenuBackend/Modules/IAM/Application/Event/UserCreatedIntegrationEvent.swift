import Foundation

/// Integration event announcing that a user account came into existence.
///
/// Consumed by `UserCreatedIntegrationEventHandler`, which onboards the local
/// `User` record. In this app the event originates **in-process** (publish
/// it wherever accounts are provisioned) and the dispatcher hands it straight to
/// that handler. In a real deployment the producer would be a separate service —
/// an identity provider's webhook, say — and the event would arrive over a
/// message bus; the transactional outbox exists to make that hand-off reliable.
struct UserCreatedIntegrationEvent: IntegrationEvent {
    static let kind: String = "users.created"

    let id: UUID
    let metadata: IntegrationEventMetadata

    let userId: String
    let email: String?
    let displayName: String?
    let registeredAt: Date

    init(
        id: UUID = UUID(),
        userId: String,
        email: String?,
        displayName: String?,
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
        self.registeredAt = registeredAt
    }
}
