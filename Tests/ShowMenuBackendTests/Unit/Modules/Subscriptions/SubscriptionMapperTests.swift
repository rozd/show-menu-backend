import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

/// Contract tests against the documents Node writes and Flutter parses
/// (`firestore_subscription_data_source.dart` + `DocumentSnapshotSubscriptionSerialization`).
@Suite("Subscription mapper (Node document shape)")
struct SubscriptionMapperTests {
    typealias F = SubscriptionFixtures

    @Test("decodes a Node (legacy sub:<uuid>) document and keeps its id")
    func decodeLegacy() throws {
        let model = try FirestoreDecoder().decode(SubscriptionModel.self, from: F.document())
        let subscription = try SubscriptionMapper().toEntity(model: model)
        #expect(subscription.id.rawValue == F.legacyId)
        #expect(subscription.status == .active)
        #expect(subscription.planId == F.planId && subscription.orderId == PurchaseFixtures.orderId)
        #expect(subscription.accountId == PurchaseFixtures.accountId)
        #expect(subscription.startedAt.timeIntervalSince1970 == 1_767_225_600.123)
        #expect(subscription.expiresAt.timeIntervalSince1970 == 1_769_904_000.123)
        #expect(subscription.suspensionReason == nil && subscription.cancellationReason == nil)
        #expect(subscription.version == .none && subscription.lastPaymentRef == nil)
    }

    @Test("decodes every status and the reasons")
    func decodeStatuses() throws {
        for status in SubscriptionStatus.allCases {
            let model = try FirestoreDecoder().decode(
                SubscriptionModel.self,
                from: F.document(status: status.rawValue, suspensionReason: "Payment failed", cancellationReason: "Payment refunded")
            )
            let subscription = try SubscriptionMapper().toEntity(model: model)
            #expect(subscription.status == status)
            #expect(subscription.suspensionReason == "Payment failed" && subscription.cancellationReason == "Payment refunded")
        }
    }

    @Test("an unknown status fails loudly")
    func unknownStatus() {
        #expect(throws: (any Error).self) {
            try FirestoreDecoder().decode(SubscriptionModel.self, from: F.document(status: "paused"))
        }
    }

    @Test("re-encoding a Node document reproduces its keys and value kinds; the additive fields are omitted when unset")
    func encodeMatchesNode() throws {
        let node = F.document()
        let model = try FirestoreDecoder().decode(SubscriptionModel.self, from: node)
        let entity = try SubscriptionMapper().toEntity(model: model)
        let encoded = try FirestoreEncoder().encode(SubscriptionMapper().toModel(entity: entity))

        #expect(Set(encoded.keys) == Set(node.keys))
        #expect((encoded["createdAt"] as? Timestamp) == F.started)
        #expect((encoded["updatedAt"] as? Timestamp) == F.updated)
        #expect((encoded["startedAt"] as? Timestamp) == F.started)
        #expect((encoded["expiresAt"] as? Timestamp) == F.expires)
        #expect(encoded["suspensionReason"] is NSNull && encoded["cancellationReason"] is NSNull)
        #expect(encoded["id"] as? String == F.legacyId)
        #expect(encoded["status"] as? String == "active")
    }

    @Test("what Flutter parses is present with the right kinds: id, accountId, planId, status as strings, startedAt/expiresAt as Timestamps")
    func flutterReadable() throws {
        let subscription = try Subscription.activate(
            accountId: "a1", orderId: "order-9", planId: "plan-1", duration: .yearly, paymentRef: "tx-1"
        )
        subscription.version = Version(1)
        let encoded = try FirestoreEncoder().encode(SubscriptionMapper().toModel(entity: subscription))
        for key in ["id", "accountId", "planId", "status"] {
            #expect(encoded[key] is String, "\(key) must be a string")
        }
        #expect(encoded["id"] as? String == "sub:9")
        #expect(encoded["status"] as? String == "active")
        #expect(encoded["startedAt"] is Timestamp && encoded["expiresAt"] is Timestamp)
        // Additive Vapor fields.
        #expect(encoded["version"] as? Int == 1 || encoded["version"] as? Int64 == 1)
        #expect(encoded["lastPaymentRef"] as? String == "tx-1")
    }

    @Test("write-back keeps millisecond precision of the timestamps")
    func millisecondPrecision() throws {
        let model = try FirestoreDecoder().decode(SubscriptionModel.self, from: F.document())
        let back = SubscriptionMapper().toModel(entity: try SubscriptionMapper().toEntity(model: model))
        #expect(back.startedAt == F.started && back.expiresAt == F.expires)
    }
}
