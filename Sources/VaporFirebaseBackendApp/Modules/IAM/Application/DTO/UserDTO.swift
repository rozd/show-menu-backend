import Foundation

struct UserDTO: Sendable, Codable {
    let id: String
    let email: String?
    let displayName: String?
    let photoURL: String?
    let emailVerified: Bool
    let disabled: Bool
    /// Current optimistic-concurrency token, also surfaced as the HTTP `ETag`.
    let version: String?
    let createdAt: String?
}
