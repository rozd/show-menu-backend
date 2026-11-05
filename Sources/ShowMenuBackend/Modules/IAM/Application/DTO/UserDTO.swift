import Foundation

struct UserDTO: Sendable, Codable {
    let id: String
    let email: String?
    let name: String?
    let avatarURL: String?
    let accounts: [String]
    /// Current optimistic-concurrency token, also surfaced as the HTTP `ETag`.
    let version: String?
    let createdAt: String?
    let updatedAt: String?
}
