//
//  DomainEventRecorder.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 10/18/25.
//

final class DomainEventRecorder<Event: DomainEvent> {
    private var events: [Event] = []

    func prepend(_ event: Event) {
        events.insert(event, at: 0)
    }

    func push(_ event: Event) {
        events.append(event)
    }

    func pull() -> [Event] {
        let pulledEvents = events
        events.removeAll()
        return pulledEvents
    }

    func clear() {
        events.removeAll()
    }
}
