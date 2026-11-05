import Foundation

enum UserEventKind: String, LifecycleEventKind {
    case userCreated = "created"
    case userUpdated = "updated"
    case userDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate. Same names as Node's
    // `UserAccountAdded` / `UserAccountRemoved`.
    case userAccountAdded = "user.account.added"
    case userAccountRemoved = "user.account.removed"

    static let created: UserEventKind = .userCreated
    static let updated: UserEventKind = .userUpdated
    static let deleted: UserEventKind = .userDeleted
}

struct UserEvent: DomainEvent {
    typealias AggregateId = User.Id
    typealias Kind = UserEventKind

    let id: UUID
    let aggregateId: User.Id
    let occurredAt: Date
    let kind: UserEventKind

    init(id: UUID, aggregateId: User.Id, kind: UserEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    /// Semantic `UserAccountAdded`.
    static func accountAdded(aggregateId: User.Id, occurredAt: Date = .now) -> UserEvent {
        UserEvent(id: UUID(), aggregateId: aggregateId, kind: .userAccountAdded, occurredAt: occurredAt)
    }

    /// Semantic `UserAccountRemoved`.
    static func accountRemoved(aggregateId: User.Id, occurredAt: Date = .now) -> UserEvent {
        UserEvent(id: UUID(), aggregateId: aggregateId, kind: .userAccountRemoved, occurredAt: occurredAt)
    }
}
