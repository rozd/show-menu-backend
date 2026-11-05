import Foundation
import FirestoreAPI
@testable import ShowMenuBackend

/// `accounts/{a}/subscriptions/{id}` documents shaped like Node's `SubscriptionMapper.toPersistence`
/// writes them (Admin SDK: `Timestamp`s, absent reasons as explicit `null`).
enum SubscriptionFixtures {
    typealias P = PurchaseFixtures

    static let started = Timestamp(seconds: 1_767_225_600, nanos: 123_000_000) // 2026-01-01T00:00:00.123Z
    static let expires = Timestamp(seconds: 1_769_904_000, nanos: 123_000_000) // 2026-02-01T00:00:00.123Z
    static let updated = Timestamp(seconds: 1_767_229_200, nanos: 5_000_000)

    static let legacyId = "sub:7d444840-9dc0-11d1-b245-5ffdce74fad2"
    static let planId = "plan-0a1b2c3d-0000-4000-8000-000000000003"

    static func document(
        id: String = legacyId, status: String = "active", suspensionReason: Any = NSNull(),
        cancellationReason: Any = NSNull()
    ) -> [String: Any] {
        [
            "id": id,
            "createdAt": started,
            "updatedAt": updated,
            "planId": planId,
            "orderId": P.orderId,
            "accountId": P.accountId,
            "status": status,
            "startedAt": started,
            "expiresAt": expires,
            "suspensionReason": suspensionReason,
            "cancellationReason": cancellationReason,
        ]
    }

    static func subscription(
        status: SubscriptionStatus = .active, expiresAt: Date, orderId: String = P.orderId,
        id: Subscription.Id? = nil, lastPaymentRef: String? = nil,
        suspensionReason: String? = nil, cancellationReason: String? = nil
    ) -> Subscription {
        Subscription(
            id: id ?? .derive(orderId: orderId), planId: planId, orderId: orderId, accountId: P.accountId,
            status: status, startedAt: Date(timeIntervalSince1970: 1_767_225_600), expiresAt: expiresAt,
            suspensionReason: suspensionReason, cancellationReason: cancellationReason, lastPaymentRef: lastPaymentRef
        )
    }
}
