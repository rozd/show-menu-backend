@testable import VaporFirebaseBackendApp

/// A capturing spy for `IntegrationEventDispatcher` that records all dispatched
/// events for test assertions.
actor SpyIntegrationEventDispatcher: IntegrationEventDispatcher {

    private(set) var dispatchedEvents: [any IntegrationEvent] = []
    private(set) var registeredHandlerTypes: [String] = []

    func dispatch<E: IntegrationEvent>(_ event: E) async {
        dispatchedEvents.append(event)
    }

    func register<H: IntegrationEventHandler>(handler: H) async {
        registeredHandlerTypes.append(String(describing: H.Event.self))
    }

    func reset() {
        dispatchedEvents.removeAll()
        registeredHandlerTypes.removeAll()
    }
}
