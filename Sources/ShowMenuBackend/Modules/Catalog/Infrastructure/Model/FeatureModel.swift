import Foundation
import FirestoreAPI

/// `features/{id}` — exactly Node's shape: `{id, category, name, description,
/// createdAt, updatedAt}` with Firestore `Timestamp`s. `description` is written as an
/// explicit `null` when absent (Node writes `null`, never omits it). `version` is the
/// template's additive optimistic-concurrency field (D6).
struct FeatureModel: Codable, Sendable, VersionedModel {
    /// A plain field, not `@DocumentID`: Node stores `id` inside the document and
    /// the encoder omits `@DocumentID` properties.
    let id: String
    let category: FeatureCategory
    let name: LocalizedString
    @ExplicitNull
    var description: LocalizedString?
    var version: Int?
    let createdAt: Timestamp
    let updatedAt: Timestamp
}

// FirestoreAPI's `ExplicitNull` wraps a plain value but isn't declared Sendable.
extension ExplicitNull: @retroactive @unchecked Sendable where Value: Sendable {}
