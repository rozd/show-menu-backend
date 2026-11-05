import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

@Suite("PubSubIntegrationEventChannel")
struct PubSubIntegrationEventChannelTests {

    private let topic = "test-integration-events"

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    // MARK: - Test Event

    struct TestIntegrationEvent: IntegrationEvent {
        static let kind = "test.event"
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

    // MARK: - Tests

    @Test("encodes envelope correctly as base64 message data")
    func encodesEnvelopeAsBase64() async throws {
        let pubSub = InMemoryPubSubClient()
        let channel = PubSubIntegrationEventChannel(
            pubSubClient: pubSub,
            topic: topic,
            logger: makeLogger()
        )

        let event = TestIntegrationEvent(value: "test-payload")

        await channel.publish(event)

        let published = await pubSub.publishedMessages
        #expect(published.count == 1)

        let message = try #require(published.first?.message)

        // Decode base64 → JSON → envelope
        let decodedData = try #require(Data(base64Encoded: message.data))
        let envelope = try JSONDecoder().decode(IntegrationEventEnvelope.self, from: decodedData)

        #expect(envelope.id == event.id)
        #expect(envelope.kind == TestIntegrationEvent.kind)
        #expect(envelope.metadata.origin == "TestModule")

        // Verify the payload round-trips back to the original event
        let decoded = try JSONDecoder().decode(TestIntegrationEvent.self, from: envelope.payload)
        #expect(decoded.value == "test-payload")
    }

    @Test("sets correct Pub/Sub message attributes")
    func setsMessageAttributes() async throws {
        let pubSub = InMemoryPubSubClient()
        let channel = PubSubIntegrationEventChannel(
            pubSubClient: pubSub,
            topic: topic,
            logger: makeLogger()
        )

        let event = TestIntegrationEvent(origin: "Items")

        await channel.publish(event)

        let published = await pubSub.publishedMessages
        let attributes = try #require(published.first?.message.attributes)

        #expect(attributes["eventKind"] == TestIntegrationEvent.kind)
        #expect(attributes["eventId"] == event.id.uuidString)
        #expect(attributes["origin"] == "Items")
    }

    @Test("forwards configured topic name")
    func forwardsTopic() async throws {
        let pubSub = InMemoryPubSubClient()
        let channel = PubSubIntegrationEventChannel(
            pubSubClient: pubSub,
            topic: "custom-topic",
            logger: makeLogger()
        )

        await channel.publish(TestIntegrationEvent())

        let published = await pubSub.publishedMessages
        #expect(published.first?.topic == "custom-topic")
    }

    @Test("fire-and-forget on PubSubClient failure")
    func fireAndForgetOnFailure() async throws {
        let pubSub = InMemoryPubSubClient()
        await pubSub.setShouldFail(true)

        let channel = PubSubIntegrationEventChannel(
            pubSubClient: pubSub,
            topic: topic,
            logger: makeLogger()
        )

        // Should not throw — errors are swallowed
        await channel.publish(TestIntegrationEvent())

        let published = await pubSub.publishedMessages
        #expect(published.isEmpty)
    }
}
