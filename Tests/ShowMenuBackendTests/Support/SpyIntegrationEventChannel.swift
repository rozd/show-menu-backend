import Foundation
@testable import ShowMenuBackend

actor SpyIntegrationEventChannel: IntegrationEventChannel {
    private(set) var publishedEvents: [any IntegrationEvent] = []

    func publish<E: IntegrationEvent>(_ event: E) async {
        publishedEvents.append(event)
    }
}
