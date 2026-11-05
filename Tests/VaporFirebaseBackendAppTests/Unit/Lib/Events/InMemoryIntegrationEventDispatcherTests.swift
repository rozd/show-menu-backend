import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

// MARK: - Test Event

private struct TestEvent: IntegrationEvent {
    static let kind = "test.event"

    let id: UUID
    let metadata: IntegrationEventMetadata
    let value: String
}

// MARK: - Capturing Handler

private final class CapturingEventHandler: IntegrationEventHandler, @unchecked Sendable {
    typealias Event = TestEvent

    private let lock = NSLock()
    private var _eventIds: [UUID] = []

    var eventIds: [UUID] {
        lock.withLock { _eventIds }
    }

    func handle(_ event: TestEvent) async throws {
        // Capture the integrationEventId bound in the task local.
        let boundId = RequestContext.integrationEventId
        if let boundId = boundId {
            lock.withLock {
                _eventIds.append(boundId)
            }
        }
    }
}

@Suite("InMemoryIntegrationEventDispatcher")
struct InMemoryIntegrationEventDispatcherTests {

    private let logger = Logger(label: "test")

    // MARK: - Event ID is bound during dispatch

    @Test("integrationEventId is bound during handler invocation")
    func eventIdIsBoundDuringDispatch() async throws {
        let dispatcher = InMemoryIntegrationEventDispatcher(logger: logger)
        let handler = CapturingEventHandler()

        await dispatcher.register(handler: handler)

        let eventId = UUID()
        let event = TestEvent(
            id: eventId,
            metadata: IntegrationEventMetadata(
                origin: "test",
                correlationId: "test-correlation"
            ),
            value: "test value"
        )

        await dispatcher.dispatch(event)

        #expect(handler.eventIds.count == 1)
        #expect(handler.eventIds[0] == eventId)
    }

    // MARK: - Event ID is not bound outside dispatch

    @Test("integrationEventId is nil outside of dispatch")
    func eventIdNotBoundOutsideDispatch() async throws {
        // Outside of dispatch, the task local should be nil.
        let id = RequestContext.integrationEventId
        #expect(id == nil)
    }
}
