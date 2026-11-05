import Foundation

enum FeatureEventKind: String, LifecycleEventKind {
    // Lifecycle (infrastructure/audit): recorded by the Repository.
    case featureCreated = "created"
    case featureUpdated = "updated"
    case featureDeleted = "deleted"

    // Semantic (domain facts): recorded by the aggregate. Same names as Node's
    // `feature.added` / `feature.updated`.
    case featureAdded = "feature.added"
    case featureModified = "feature.updated"

    static let created: FeatureEventKind = .featureCreated
    static let updated: FeatureEventKind = .featureUpdated
    static let deleted: FeatureEventKind = .featureDeleted
}

struct FeatureEvent: DomainEvent {
    typealias AggregateId = Feature.Id
    typealias Kind = FeatureEventKind

    let id: UUID
    let aggregateId: Feature.Id
    let occurredAt: Date
    let kind: FeatureEventKind

    init(id: UUID, aggregateId: Feature.Id, kind: FeatureEventKind, occurredAt: Date) {
        self.id = id
        self.aggregateId = aggregateId
        self.kind = kind
        self.occurredAt = occurredAt
    }

    /// Semantic `FeatureAdded`.
    static func featureAdded(aggregateId: Feature.Id, occurredAt: Date = .now) -> FeatureEvent {
        FeatureEvent(id: UUID(), aggregateId: aggregateId, kind: .featureAdded, occurredAt: occurredAt)
    }

    /// Semantic `FeatureUpdated`.
    static func featureModified(aggregateId: Feature.Id, occurredAt: Date = .now) -> FeatureEvent {
        FeatureEvent(id: UUID(), aggregateId: aggregateId, kind: .featureModified, occurredAt: occurredAt)
    }
}
