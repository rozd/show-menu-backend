import Foundation

enum OrderEventKind: String, LifecycleEventKind {
    // Lifecycle (infrastructure/audit): recorded by the Repository.
    case orderCreated = "created"
    case orderUpdated = "updated"
    case orderDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate. Same names as Node's
    // `order.*` events.
    case orderPlaced = "order.created"
    case orderCompleted = "order.completed"
    case orderFailed = "order.failed"
    case orderCancelled = "order.cancelled"
    case orderRefunded = "order.refunded"

    static let created: OrderEventKind = .orderCreated
    static let updated: OrderEventKind = .orderUpdated
    static let deleted: OrderEventKind = .orderDeleted
}

struct OrderEvent: DomainEvent {
    typealias AggregateId = Order.Id
    typealias Kind = OrderEventKind

    let id: UUID
    let aggregateId: Order.Id
    let occurredAt: Date
    let kind: OrderEventKind

    init(id: UUID, aggregateId: Order.Id, kind: OrderEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    static func semantic(_ kind: OrderEventKind, aggregateId: Order.Id, occurredAt: Date = .now) -> OrderEvent {
        OrderEvent(id: UUID(), aggregateId: aggregateId, kind: kind, occurredAt: occurredAt)
    }
}
