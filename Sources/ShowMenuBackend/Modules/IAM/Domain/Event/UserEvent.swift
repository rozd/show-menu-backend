import Foundation

enum UserEventKind: String, LifecycleEventKind {
    case userCreated = "created"
    case userUpdated = "updated"
    case userDeleted = "deleted"

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
}
