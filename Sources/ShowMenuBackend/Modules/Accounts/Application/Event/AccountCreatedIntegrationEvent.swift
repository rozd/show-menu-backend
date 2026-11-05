import Foundation

/// Integration event published when a client creates `accounts/{accountId}`.
///
/// Published by `EventarcWebhookController` upon receiving a
/// `google.cloud.firestore.document.v1.created` CloudEvent forwarded by
/// `firestore-forwarder`. Consumed by two independent, inboxed command handlers:
/// `LinkAccountToCreator` (IAM) and `GrantAccountOwnerPermission` (Accounts).
struct AccountCreatedIntegrationEvent: IntegrationEvent {
    static let kind: String = "accounts.created"

    let id: UUID
    let metadata: IntegrationEventMetadata

    let accountId: String
    /// Uid of the creating user (`accounts/{id}.creator`).
    let creatorId: String
    let name: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        accountId: String,
        creatorId: String,
        name: String? = nil,
        createdAt: Date = .now,
        correlationId: TraceID? = nil
    ) {
        self.id = id
        self.metadata = IntegrationEventMetadata(
            origin: "Accounts",
            correlationId: correlationId,
            occurredAt: .now
        )
        self.accountId = accountId
        self.creatorId = creatorId
        self.name = name
        self.createdAt = createdAt
    }
}
