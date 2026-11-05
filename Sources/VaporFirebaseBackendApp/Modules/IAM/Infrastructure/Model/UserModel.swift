import Foundation
import FirestoreAPI

struct UserModel: Codable, Sendable, VersionedModel {
    @DocumentID
    var id: String
    let email: String?
    let displayName: String?
    let photoURL: String?
    let emailVerified: Bool?
    let disabled: Bool?
    /// Optimistic-concurrency counter. Absent on documents written before
    /// versioning (decodes to `nil`), which the binding treats as `Version.none`.
    var version: Int?
    let createdAt: Date?

    init(
        id: String,
        email: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        emailVerified: Bool = false,
        disabled: Bool = false,
        version: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.emailVerified = emailVerified
        self.disabled = disabled
        self.version = version
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName
        case photoURL = "photoUrl"
        case emailVerified
        case disabled
        case version
        case createdAt
    }
}
