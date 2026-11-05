import Foundation

protocol GeneratableIdentifier: Sendable {
    static func generate() -> Self
}

protocol LifecycleEventKind: Codable, Equatable, Sendable {
    static var created: Self { get }
    static var updated: Self { get }
    static var deleted: Self { get }
}

protocol DomainEvent: Identifiable, Codable, Equatable, Sendable where ID: GeneratableIdentifier {
    associatedtype AggregateId: EntityId
    associatedtype Kind: LifecycleEventKind

    var aggregateId: AggregateId { get }
    var occurredAt: Date { get }
    var kind: Kind { get }

    init(id: ID, aggregateId: AggregateId, kind: Kind, occurredAt: Date)
}

// MARK: - Lifecycle Event Factories

extension DomainEvent {
    static func created(
        aggregateId: AggregateId,
        id: ID,
        occurredAt: Date = .now
    ) -> Self {
        .init(id: id, aggregateId: aggregateId, kind: .created, occurredAt: occurredAt)
    }

    static func updated(
        aggregateId: AggregateId,
        id: ID,
        occurredAt: Date = .now
    ) -> Self {
        .init(id: id, aggregateId: aggregateId, kind: .updated, occurredAt: occurredAt)
    }

    static func deleted(
        aggregateId: AggregateId,
        id: ID,
        occurredAt: Date = .now
    ) -> Self {
        .init(id: id, aggregateId: aggregateId, kind: .deleted, occurredAt: occurredAt)
    }
}

extension DomainEvent {
    static func created(
        aggregateId: AggregateId,
        occurredAt: Date = .now
    ) -> Self {
        created(aggregateId: aggregateId, id: ID.generate(), occurredAt: occurredAt)
    }

    static func updated(
        aggregateId: AggregateId,
        occurredAt: Date = .now
    ) -> Self {
        updated(aggregateId: aggregateId, id: ID.generate(), occurredAt: occurredAt)
    }

    static func deleted(
        aggregateId: AggregateId,
        occurredAt: Date = .now
    ) -> Self {
        deleted(aggregateId: aggregateId, id: ID.generate(), occurredAt: occurredAt)
    }

    init(aggregateId: AggregateId, kind: Kind, occurredAt: Date) {
        self.init(id: ID.generate(), aggregateId: aggregateId, kind: kind, occurredAt: occurredAt)
    }
}

// MARK: - UUID with GeneratableIdentifier

extension UUID: GeneratableIdentifier {
    static func generate() -> UUID { UUID() }
}
