import Foundation

struct UserDTO: Sendable, Codable {
    let id: String
    let email: String?
    let phone: String?
    let username: String?
    let displayName: String?
    let photoURL: String?
    let emailVerified: Bool
    let phoneVerified: Bool
    let disabled: Bool
    /// Authorization role names, sorted for stable output.
    let roles: [String]
    /// Current optimistic-concurrency token, also surfaced as the HTTP `ETag`.
    let version: String?
    let createdAt: String?
}
