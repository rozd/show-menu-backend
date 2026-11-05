@testable import VaporFirebaseBackendApp

/// A capturing spy for `DomainEventDispatcher` that records all dispatched
/// events and registered handler types for test assertions.
actor SpyDomainEventDispatcher: DomainEventDispatcher {

    private(set) var dispatchedEvents: [any DomainEvent] = []
    private(set) var registeredHandlerTypes: [String] = []

    func dispatch(event: any DomainEvent) async {
        dispatchedEvents.append(event)
    }

    func dispatch(events: [any DomainEvent]) async {
        dispatchedEvents.append(contentsOf: events)
    }

    func register<Handler: DomainEventHandler>(handler: Handler) async {
        registeredHandlerTypes.append(String(describing: Handler.Event.self))
    }

    func reset() {
        dispatchedEvents.removeAll()
        registeredHandlerTypes.removeAll()
    }
}
