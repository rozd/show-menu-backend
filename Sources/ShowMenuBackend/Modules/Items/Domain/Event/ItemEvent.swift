import Foundation

enum ItemEventKind: String, LifecycleEventKind {
    case itemCreated = "created"
    case itemUpdated = "updated"
    case itemDeleted = "deleted"

    static let created: ItemEventKind = .itemCreated
    static let updated: ItemEventKind = .itemUpdated
    static let deleted: ItemEventKind = .itemDeleted
}

struct ItemEvent: DomainEvent {
    typealias AggregateId = Item.Id
    typealias Kind = ItemEventKind

    let id: UUID
    let aggregateId: Item.Id
    let occurredAt: Date
    let kind: ItemEventKind

    init(id: UUID, aggregateId: Item.Id, kind: ItemEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }
}
