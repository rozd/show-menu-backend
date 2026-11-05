//
//  AggregateRoot.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 9/5/25.
//

protocol AggregateRoot: Entity {
    associatedtype Event: DomainEvent where Event.AggregateId == Self.ID

    var events: DomainEventRecorder<Event> { get }

    /// Opaque optimistic-concurrency token, owned by the persistence layer.
    /// Loaded with the aggregate and advanced on each successful write; the
    /// domain carries it but never inspects or hand-increments it.
    var version: Version { get set }

    func record(event: Event)
    func clearEvents()
    func pullEvents() -> [Event]
}

extension AggregateRoot {

    func record(event: Event) {
        events.push(event)
    }

    func clearEvents() {
        events.clear()
    }
    
    func pullEvents() -> [Event] {
        return events.pull()
    }
}
