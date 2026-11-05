import Foundation
import FirestoreAPI
import Crypto

/// `plan_skus/{sha256(SKU)}` — uniqueness marker written together with every new
/// plan. Its document id is derived from the exact SKU, so the transactional
/// `create` precondition (`exists == false`) makes two concurrent creates of the
/// same SKU conflict at commit; the transaction runner then retries and the
/// retry's marker read answers 409. Backend-owned; Node-created plans have no
/// marker (the repository falls back to a direct query for those).
struct PlanSKUModel: Codable, Sendable {
    let id: String
    let sku: String
    let planId: String
    let createdAt: Timestamp

    /// Hex SHA-256 of the exact SKU: path-safe (SKUs may contain `/`) and case-sensitive
    /// like Node's `where("SKU", "==", sku)`.
    static func documentId(for sku: String) -> String {
        SHA256.hash(data: Data(sku.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
