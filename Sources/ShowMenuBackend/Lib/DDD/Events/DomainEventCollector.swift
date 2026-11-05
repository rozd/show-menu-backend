//
//  DomainEventCollector.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 10/24/25.
//

protocol DomainEventCollector: Sendable {
    func capture<T: DomainEvent>(_ event: T) async
    func capture<T: DomainEvent>(_ events: [T]) async

    func drain() async -> [any DomainEvent]
}

// MARK: - Default Implementation

actor InMemoryDomainEventCollector: DomainEventCollector {
    private var events: [any DomainEvent] = []

    func capture<T: DomainEvent>(_ event: T) async {
        events.append(event)
    }

    func capture<T: DomainEvent>(_ events: [T]) async {
        self.events.append(contentsOf: events)
    }

    func drain() async -> [any DomainEvent] {
        let events = self.events
        self.events.removeAll()
        return events
    }
}
