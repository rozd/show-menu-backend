import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("CloudEventsHeaders — stable integration event id")
struct CloudEventsHeadersTests {

    private func headers(
        source: String = "//firebaseauth.googleapis.com/projects/demo-project",
        id: String = "evt-1"
    ) -> CloudEventsHeaders {
        CloudEventsHeaders(
            specVersion: "1.0",
            type: CloudEventsHeaders.firebaseAuthUserCreated,
            source: source,
            id: id,
            time: Date(),
            subject: nil
        )
    }

    @Test("a redelivery (same source + id) maps to the same integration event id")
    func redeliveryIsStable() {
        // Separate parses of the same CloudEvent, e.g. Eventarc retrying the webhook.
        let first = headers()
        let redelivery = CloudEventsHeaders(
            specVersion: "1.0",
            type: first.type,
            source: first.source,
            id: first.id,
            time: first.time.addingTimeInterval(30),
            subject: nil
        )
        #expect(first.integrationEventId == redelivery.integrationEventId)
    }

    @Test("a different CloudEvent id maps to a different integration event id")
    func differentIdDiffers() {
        #expect(headers(id: "evt-1").integrationEventId != headers(id: "evt-2").integrationEventId)
    }

    @Test("the same id from a different source maps to a different integration event id")
    func differentSourceDiffers() {
        #expect(
            headers(source: "//a/projects/p").integrationEventId
                != headers(source: "//b/projects/p").integrationEventId
        )
    }

    @Test("source and id cannot run together ambiguously")
    func fieldsAreSeparated() {
        #expect(
            headers(source: "ab", id: "c").integrationEventId
                != headers(source: "a", id: "bc").integrationEventId
        )
    }

    @Test("the derived id is an RFC 9562 version-8, RFC 4122-variant UUID")
    func versionAndVariantBits() {
        let uuid = headers().integrationEventId.uuid
        #expect(uuid.6 >> 4 == 0x8)
        #expect(uuid.8 >> 6 == 0b10)
    }
}
