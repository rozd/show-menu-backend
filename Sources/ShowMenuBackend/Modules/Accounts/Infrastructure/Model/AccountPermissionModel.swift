import Foundation

/// `accounts/{accountId}/permissions/{uid}` — exactly Node's shape
/// `{role, permissions}` (no timestamps, no id; the document id is the user's uid).
/// Flutter reads it directly.
struct AccountPermissionModel: Codable, Sendable, Equatable {
    var role: String
    var permissions: [String]
}
