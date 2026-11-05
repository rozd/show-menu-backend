import Foundation

enum PlanEventKind: String, LifecycleEventKind {
    // Lifecycle (infrastructure/audit): recorded by the Repository.
    case planCreated = "created"
    case planUpdated = "updated"
    case planDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate. Same name as Node's
    // `plan.created`.
    case planAdded = "plan.created"
    case planActivated = "plan.activated"
    case planDeactivated = "plan.deactivated"
    case planFeatureAdded = "plan.feature.added"
    case planFeatureRemoved = "plan.feature.removed"

    static let created: PlanEventKind = .planCreated
    static let updated: PlanEventKind = .planUpdated
    static let deleted: PlanEventKind = .planDeleted
}

struct PlanEvent: DomainEvent {
    typealias AggregateId = Plan.Id
    typealias Kind = PlanEventKind

    let id: UUID
    let aggregateId: Plan.Id
    let occurredAt: Date
    let kind: PlanEventKind

    init(id: UUID, aggregateId: Plan.Id, kind: PlanEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    /// Semantic `PlanCreated`.
    static func planAdded(aggregateId: Plan.Id, occurredAt: Date = .now) -> PlanEvent {
        PlanEvent(id: UUID(), aggregateId: aggregateId, kind: .planAdded, occurredAt: occurredAt)
    }

    /// Semantic `PlanActivated`.
    static func planActivated(aggregateId: Plan.Id, occurredAt: Date = .now) -> PlanEvent {
        PlanEvent(id: UUID(), aggregateId: aggregateId, kind: .planActivated, occurredAt: occurredAt)
    }

    /// Semantic `PlanDeactivated`.
    static func planDeactivated(aggregateId: Plan.Id, occurredAt: Date = .now) -> PlanEvent {
        PlanEvent(id: UUID(), aggregateId: aggregateId, kind: .planDeactivated, occurredAt: occurredAt)
    }

    /// Semantic `PlanFeatureAdded`.
    static func planFeatureAdded(aggregateId: Plan.Id, occurredAt: Date = .now) -> PlanEvent {
        PlanEvent(id: UUID(), aggregateId: aggregateId, kind: .planFeatureAdded, occurredAt: occurredAt)
    }

    /// Semantic `PlanFeatureRemoved` (Node recorded `plan.feature.added` here — bug 7).
    static func planFeatureRemoved(aggregateId: Plan.Id, occurredAt: Date = .now) -> PlanEvent {
        PlanEvent(id: UUID(), aggregateId: aggregateId, kind: .planFeatureRemoved, occurredAt: occurredAt)
    }
}
