import Foundation

/// Minimal read projection required by the `Mapper` contract. No S14 endpoint returns a
/// subscription body (Flutter streams the Firestore documents).
struct SubscriptionDTO: Codable, Sendable, Equatable {
    let id: String
    let accountId: String
    let planId: String
    let orderId: String
    let status: String
    let startedAt: String
    let expiresAt: String
}
