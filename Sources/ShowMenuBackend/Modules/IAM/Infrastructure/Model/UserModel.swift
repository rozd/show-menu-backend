import Foundation

struct UserModel: Codable, Sendable, VersionedModel {
    var id: String
    let email: String?
    let phone: String?
    let username: String?
    let displayName: String?
    let photoURL: String?
    let emailVerified: Bool?
    let phoneVerified: Bool?
    let disabled: Bool?
    /// Authorization role names. Absent on documents written before roles were
    /// introduced (decodes to `nil`), which maps to an empty role set.
    let roles: [String]?
    /// Optimistic-concurrency counter. Absent on documents written before
    /// versioning was introduced (decodes to `nil`), which the binding treats as
    /// `Version.none`.
    var version: Int?
    let createdAt: Date?

    init(
        id: String,
        email: String? = nil,
        phone: String? = nil,
        username: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        emailVerified: Bool = false,
        phoneVerified: Bool = false,
        disabled: Bool = false,
        roles: [String]? = nil,
        version: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.username = username
        self.displayName = displayName
        self.photoURL = photoURL
        self.emailVerified = emailVerified
        self.phoneVerified = phoneVerified
        self.disabled = disabled
        self.roles = roles
        self.version = version
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case username
        case displayName
        case photoURL = "photoUrl"
        case emailVerified
        case phoneVerified
        case disabled
        case roles
        case version
        case createdAt
    }
}
