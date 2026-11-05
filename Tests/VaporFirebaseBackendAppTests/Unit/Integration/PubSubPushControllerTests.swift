import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

@Suite("PubSubPushController")
struct PubSubPushControllerTests {

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    // MARK: - Test Event

    struct TestPushEvent: IntegrationEvent {
        static let kind = "test.push_event"
        let id: UUID
        let metadata: IntegrationEventMetadata
        let value: String

        init(
            id: UUID = UUID(),
            value: String = "hello",
            origin: String = "TestModule"
        ) {
            self.id = id
            self.metadata = .from(origin: origin)
            self.value = value
        }
    }

    // MARK: - Helpers

    /// Encode an integration event into a `PubSubPushEnvelope`, mirroring
    /// the publish path: event → envelope → JSON → base64 → push message.
    private func makePushEnvelope(
        _ event: some IntegrationEvent,
        messageId: String = UUID().uuidString,
        subscription: String = "projects/test/subscriptions/integration-events-sub"
    ) throws -> PubSubPushEnvelope {
        let coder = JSONIntegrationEventCoder(registry: .shared)
        let envelope = try coder.encode(event)
        let json = try envelope.toJSON()
        let base64 = json.base64EncodedString()

        return PubSubPushEnvelope(
            message: .init(
                data: base64,
                attributes: [
                    "eventKind": type(of: event).kind,
                    "eventId": event.id.uuidString,
                    "origin": event.metadata.origin,
                ],
                messageId: messageId,
                publishTime: nil
            ),
            subscription: subscription
        )
    }

    private func makeSUT(
        registry: IntegrationEventRegistry = IntegrationEventRegistry()
    ) -> (
        controller: PubSubPushController,
        dispatcher: SpyIntegrationEventDispatcher
    ) {
        let dispatcher = SpyIntegrationEventDispatcher()
        let controller = PubSubPushController(
            dispatcher: dispatcher,
            coder: JSONIntegrationEventCoder(registry: registry),
            logger: makeLogger()
        )
        return (controller, dispatcher)
    }

    // MARK: - Tests

    @Test("decodes and dispatches a valid push message")
    func decodesAndDispatches() async throws {
        let registry = IntegrationEventRegistry()
        await registry.register(TestPushEvent.self)
        let (controller, dispatcher) = makeSUT(registry: registry)

        let event = TestPushEvent(value: "from-push")
        let envelope = try makePushEnvelope(event)

        let status = await controller.handle(envelope)

        #expect(status == .ok)

        let dispatched = await dispatcher.dispatchedEvents
        #expect(dispatched.count == 1)
        let dispatchedEvent = try #require(dispatched.first as? TestPushEvent)
        #expect(dispatchedEvent.value == "from-push")
        #expect(dispatchedEvent.id == event.id)
    }

    @Test("returns 200 for invalid base64")
    func invalidBase64Returns200() async {
        let (controller, dispatcher) = makeSUT()

        let envelope = PubSubPushEnvelope(
            message: .init(
                data: "not-valid-base64!!!",
                attributes: nil,
                messageId: "msg-1",
                publishTime: nil
            ),
            subscription: "projects/test/subscriptions/test-sub"
        )

        let status = await controller.handle(envelope)

        #expect(status == .ok)

        let dispatched = await dispatcher.dispatchedEvents
        #expect(dispatched.isEmpty)
    }

    @Test("returns 200 for unknown event kind")
    func unknownEventKindReturns200() async throws {
        // Registry WITHOUT TestPushEvent registered → decode will fail
        let (controller, dispatcher) = makeSUT()

        let event = TestPushEvent(value: "unknown-kind")
        let envelope = try makePushEnvelope(event)

        let status = await controller.handle(envelope)

        #expect(status == .ok)

        let dispatched = await dispatcher.dispatchedEvents
        #expect(dispatched.isEmpty)
    }

    @Test("returns 200 for valid message")
    func validMessageReturns200() async throws {
        let registry = IntegrationEventRegistry()
        await registry.register(TestPushEvent.self)
        let (controller, _) = makeSUT(registry: registry)

        let event = TestPushEvent(value: "ok")
        let envelope = try makePushEnvelope(event)

        let status = await controller.handle(envelope)
        #expect(status == .ok)
    }

    @Test("multiple events dispatched independently")
    func multipleEventsDispatched() async throws {
        let registry = IntegrationEventRegistry()
        await registry.register(TestPushEvent.self)
        let (controller, dispatcher) = makeSUT(registry: registry)

        let event1 = TestPushEvent(value: "first")
        let event2 = TestPushEvent(value: "second")

        let status1 = await controller.handle(try makePushEnvelope(event1))
        let status2 = await controller.handle(try makePushEnvelope(event2))

        #expect(status1 == .ok)
        #expect(status2 == .ok)

        let dispatched = await dispatcher.dispatchedEvents
        #expect(dispatched.count == 2)

        let first = try #require(dispatched[0] as? TestPushEvent)
        let second = try #require(dispatched[1] as? TestPushEvent)
        #expect(first.value == "first")
        #expect(second.value == "second")
    }

    @Test("returns 200 for invalid JSON in base64")
    func invalidJsonReturns200() async {
        let (controller, dispatcher) = makeSUT()

        // Valid base64 but not valid JSON
        let data = "this is not json".data(using: .utf8)!
        let envelope = PubSubPushEnvelope(
            message: .init(
                data: data.base64EncodedString(),
                attributes: nil,
                messageId: "msg-bad-json",
                publishTime: nil
            ),
            subscription: "projects/test/subscriptions/test-sub"
        )

        let status = await controller.handle(envelope)

        #expect(status == .ok)

        let dispatched = await dispatcher.dispatchedEvents
        #expect(dispatched.isEmpty)
    }
}
