import Foundation

struct ItemDTO: Sendable, Codable {
    let id: String
    let name: String
    let description: String?
    /// Current optimistic-concurrency token, also surfaced as the HTTP `ETag`.
    let version: String?
    let createdAt: String?
    let updatedAt: String?
}

/// A page of items.
///
/// `total` is the size of the whole `items` collection, read by a **separate
/// count aggregation**. It is not atomic with the page, so it can disagree
/// with the page under concurrent writes. Also, because the page is ordered by
/// `createdAt`, a document lacking a `createdAt` field never appears in any
/// page but is still counted (every `Item` is created with `createdAt`, so this
/// only affects foreign/legacy documents).
struct ItemPageDTO: Sendable, Codable {
    let items: [ItemDTO]
    let total: Int
    let limit: Int
    let offset: Int
}
