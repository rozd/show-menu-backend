import Foundation
import FirestoreAPI

/// `users/{uid}` — exactly Node's shape: `{id, email, name, avatarURL, accounts,
/// createdAt, updatedAt}` with Firestore `Timestamp`s. Absent `email`/`name`/`avatarURL`
/// are written as explicit `null` (Node writes `null`). `version` is the template's
/// additive optimistic-concurrency field (D6) and `disabled` a template-only flag
/// written only when `true`; both are absent on Node-created documents.
///
/// `id` is a plain field, not `@DocumentID`: Node stores it inside the document and
/// the encoder omits `@DocumentID` properties.
struct UserModel: Codable, Sendable, VersionedModel {
    let id: String
    @ExplicitNull
    var email: String?
    @ExplicitNull
    var name: String?
    @ExplicitNull
    var avatarURL: String?
    var accounts: [String]?
    var disabled: Bool?
    /// Absent on documents written before versioning (decodes to `nil`), which the
    /// binding treats as `Version.none`.
    var version: Int?
    var createdAt: Timestamp?
    var updatedAt: Timestamp?

    init(
        id: String,
        email: String? = nil,
        name: String? = nil,
        avatarURL: String? = nil,
        accounts: [String]? = [],
        disabled: Bool? = nil,
        version: Int? = nil,
        createdAt: Timestamp? = nil,
        updatedAt: Timestamp? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.accounts = accounts
        self.disabled = disabled
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
