import Foundation
import FirestoreAPI

/// `plans/{id}` — exactly Node's shape: `{id, SKU, createdAt, updatedAt, name,
/// description, isActive, prices[{price{currency{symbol,name,base,digits},amount},
/// duration}], features[{featureId, quota{unit,limit}}]}` with Firestore
/// `Timestamp`s. Flutter reads this collection directly (`name`, `description`,
/// `prices`, `isActive`, `id`). `version` is the template's additive
/// optimistic-concurrency field (D6).
struct PlanModel: Codable, Sendable, VersionedModel {
    /// A plain field, not `@DocumentID` (Node stores `id` inside the document).
    let id: String
    let SKU: String
    let name: LocalizedString
    let description: LocalizedString
    let isActive: Bool
    let prices: [PlanPrice]
    let features: [PlanFeature]
    var version: Int?
    let createdAt: Timestamp
    let updatedAt: Timestamp
}
