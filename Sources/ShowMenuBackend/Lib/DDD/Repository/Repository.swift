//
//  Repository.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 9/13/25.
//

protocol Repository: Sendable {
    associatedtype Entity: AggregateRoot
    associatedtype Model
    associatedtype DTO

    var mapper: any Mapper<Entity, Model, DTO> { get }
    var context: any UnitOfWorkContext { get }

    func fetch(byId id: Entity.ID) async throws -> Entity?

    func doInsert(entities: [Entity]) async throws

    func doUpdate(entities: [Entity]) async throws

    func doDelete(entities: [Entity]) async throws
}

extension Repository {

    func insert(entity: Entity) async throws {
        entity.events.prepend(.created(aggregateId: entity.id))
        try await doInsert(entities: [entity])
        await context.collector.capture(entity.pullEvents())
    }

    func insert(entities: [Entity]) async throws {
        entities.forEach {
            $0.events.prepend(.created(aggregateId: $0.id))
        }
        try await doInsert(entities: entities)
        await context.collector.capture(entities.flatMap { $0.pullEvents() })
    }

    func update(entity: Entity) async throws {
        entity.record(event: .updated(aggregateId: entity.id))
        try await doUpdate(entities: [entity])
        await context.collector.capture(entity.pullEvents())
    }

    func update(entities: [Entity]) async throws {
        entities.forEach {
            $0.record(event: .updated(aggregateId: $0.id))
        }
        try await doUpdate(entities: entities)
        await context.collector.capture(entities.flatMap { $0.pullEvents() })
    }

    func delete(entity: Entity) async throws {
        entity.record(event: .deleted(aggregateId: entity.id))
        try await doDelete(entities: [entity])
        await context.collector.capture(entity.pullEvents())
    }

    func delete(entities: [Entity]) async throws {
        entities.forEach {
            $0.record(event: .deleted(aggregateId: $0.id))
        }
        try await doDelete(entities: entities)
        await context.collector.capture(entities.flatMap { $0.pullEvents() })
    }

}
