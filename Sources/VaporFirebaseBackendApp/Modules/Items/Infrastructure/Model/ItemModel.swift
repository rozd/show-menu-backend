import Foundation
import FirestoreAPI

struct ItemModel: Codable, Sendable, VersionedModel {
    @DocumentID
    var id: String
    let name: String
    let description: String?

    /// Optimistic-concurrency counter. Absent on documents written before
    /// versioning (decodes to `nil`), which the binding treats as `Version.none`.
    var version: Int?

    let createdAt: Timestamp?
    let updatedAt: Timestamp?
}
