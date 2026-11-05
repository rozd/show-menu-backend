import Foundation
import FirestoreAPI

/// `accounts/{accountId}/subscriptions/{id}` — Node's `SubscriptionModel`:
/// `{id, createdAt, updatedAt, planId, orderId, accountId, status, startedAt, expiresAt,
/// suspensionReason, cancellationReason}` with Firestore `Timestamp`s; the two reasons are
/// explicit `null` when absent. Flutter reads `id, accountId, planId, status` (by name),
/// `startedAt`, `expiresAt` (`Timestamp`).
///
/// Additive Vapor fields (Flutter and Node ignore them): `version` (D6) and `lastPaymentRef`
/// (idempotency marker, omitted until the first payment is applied). Legacy documents lack both.
struct SubscriptionModel: Codable, Sendable, VersionedModel, Equatable {
    /// A plain field, not `@DocumentID` (Node stores `id` inside the document).
    let id: String
    let createdAt: Timestamp
    let updatedAt: Timestamp
    let planId: String
    let orderId: String
    let accountId: String
    let status: SubscriptionStatus
    let startedAt: Timestamp
    let expiresAt: Timestamp
    let suspensionReason: String?
    let cancellationReason: String?
    let lastPaymentRef: String?
    var version: Int?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, planId, orderId, accountId, status, startedAt, expiresAt
        case suspensionReason, cancellationReason, lastPaymentRef, version
    }

    init(
        id: String, createdAt: Timestamp, updatedAt: Timestamp, planId: String, orderId: String,
        accountId: String, status: SubscriptionStatus, startedAt: Timestamp, expiresAt: Timestamp,
        suspensionReason: String?, cancellationReason: String?, lastPaymentRef: String?, version: Int?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planId = planId
        self.orderId = orderId
        self.accountId = accountId
        self.status = status
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.suspensionReason = suspensionReason
        self.cancellationReason = cancellationReason
        self.lastPaymentRef = lastPaymentRef
        self.version = version
    }

    /// Legacy-tolerant: the reasons, `lastPaymentRef` and `version` may be absent.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.createdAt = try c.decode(Timestamp.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Timestamp.self, forKey: .updatedAt)
        self.planId = try c.decode(String.self, forKey: .planId)
        self.orderId = try c.decode(String.self, forKey: .orderId)
        self.accountId = try c.decode(String.self, forKey: .accountId)
        self.status = try c.decode(SubscriptionStatus.self, forKey: .status)
        self.startedAt = try c.decode(Timestamp.self, forKey: .startedAt)
        self.expiresAt = try c.decode(Timestamp.self, forKey: .expiresAt)
        self.suspensionReason = try c.decodeIfPresent(String.self, forKey: .suspensionReason)
        self.cancellationReason = try c.decodeIfPresent(String.self, forKey: .cancellationReason)
        self.lastPaymentRef = try c.decodeIfPresent(String.self, forKey: .lastPaymentRef)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(planId, forKey: .planId)
        try c.encode(orderId, forKey: .orderId)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(status, forKey: .status)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(suspensionReason, forKey: .suspensionReason)
        try c.encode(cancellationReason, forKey: .cancellationReason)
        try c.encodeIfPresent(lastPaymentRef, forKey: .lastPaymentRef)
        try c.encodeIfPresent(version, forKey: .version)
    }
}
