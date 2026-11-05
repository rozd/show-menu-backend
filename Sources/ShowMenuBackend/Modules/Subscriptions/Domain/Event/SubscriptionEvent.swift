import Foundation

enum SubscriptionEventKind: String, LifecycleEventKind {
    // Lifecycle (infrastructure/audit): recorded by the Repository.
    case subscriptionCreated = "created"
    case subscriptionUpdated = "updated"
    case subscriptionDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate. Node's `subscription.*` events
    // (`expiring` arrives with the expiration job, S15).
    case subscriptionActivated = "subscription.activated"
    case subscriptionExpired = "subscription.expired"
    case subscriptionSuspended = "subscription.suspended"
    case subscriptionCancelled = "subscription.cancelled"

    static let created: SubscriptionEventKind = .subscriptionCreated
    static let updated: SubscriptionEventKind = .subscriptionUpdated
    static let deleted: SubscriptionEventKind = .subscriptionDeleted
}

struct SubscriptionEvent: DomainEvent {
    typealias AggregateId = Subscription.Id
    typealias Kind = SubscriptionEventKind

    let id: UUID
    let aggregateId: Subscription.Id
    let occurredAt: Date
    let kind: SubscriptionEventKind

    init(id: UUID, aggregateId: Subscription.Id, kind: SubscriptionEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    static func semantic(
        _ kind: SubscriptionEventKind, aggregateId: Subscription.Id, occurredAt: Date = .now
    ) -> SubscriptionEvent {
        SubscriptionEvent(id: UUID(), aggregateId: aggregateId, kind: kind, occurredAt: occurredAt)
    }
}
