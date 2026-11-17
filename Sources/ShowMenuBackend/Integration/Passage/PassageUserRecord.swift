import Foundation
import Fluent
import FluentKit
import Passage
import PassageFluent

/// Passage overlay record conforming to `PassageUserModel`.
///
/// This class is the Fluent lens over the shared `users` table, exposing only
/// Passage-owned columns for authentication and verification. It deliberately
/// does NOT declare IAM-owned fields (`display_name`, `photo_url`, `disabled`,
/// `roles`, `version`) — the IAM module has its own `UserModel` reading the same
/// table's remaining columns through a separate `FluentUserDataSource`.
///
/// The two lenses coexist safely because FluentKit's UPDATE/INSERT operations
/// touch only declared fields: IAM writes only IAM columns, Passage writes
/// only Passage columns. `email`, `phone`, `username`, `email_verified` and
/// `phone_verified` are columns both lenses declare — Passage writes them
/// (registration, identifier verification), IAM reads them (its only write
/// path, the onboarding upsert, early-returns for existing rows).
final class PassageUserRecord: Model, PassageUserModel, ModelSessionAuthenticatable, @unchecked Sendable {
    static let schema = "users"

    /// UUID string ID — matches the shared `users` table.
    /// `@ID(custom: "id", generatedBy: .user)` + String means Fluent never generates it;
    /// `passageMakeUser` MUST mint `UUID().uuidString` or the write fails with NULL PK.
    @ID(custom: "id", generatedBy: .user)
    var id: String?

    /// Optional email column — shared with IAM's UserModel but rarely written after provisioning.
    /// Passage identifiers table holds the authoritative email/phone/username;
    /// this column is sync'd on identifier verification (see `passageDidMarkIdentifierVerified`).
    @OptionalField(key: "email")
    var email: String?

    /// Optional username column — shared with IAM's UserModel, written by Passage
    /// on username registration, read by IAM like `email`.
    @OptionalField(key: "username")
    var username: String?

    /// Optional phone column — shared with IAM's UserModel, written by Passage
    /// on phone registration, read by IAM like `email`.
    @OptionalField(key: "phone")
    var phone: String?

    /// Optional password hash — Passage-owned, bcrypt-hashed or nil for passwordless auth.
    @OptionalField(key: "password_hash")
    var passwordHash: String?

    /// Email verification flag — Passage-owned, synced when an email identifier is verified.
    @OptionalField(key: "email_verified")
    var emailVerified: Bool?

    /// Phone verification flag — shared with IAM's UserModel, synced by Passage
    /// when a phone identifier is verified, read by IAM like `email_verified`.
    @OptionalField(key: "phone_verified")
    var phoneVerified: Bool?

    /// Creation timestamp — managed by Fluent.
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    // MARK: - PassageUserModel Conformance

    /// Mints a new UUID string ID and initializes verification flags to false.
    /// Called by Passage's generic `UserStore.create(identifier:with:)`.
    /// IMPORTANT: MUST set `id` to a pre-generated UUID string — Fluent's `@ID(generatedBy: .user)`
    /// never auto-generates, and a NULL PK causes INSERT to fail.
    static func passageMakeUser(identifier: Identifier, passwordHash: String?) throws -> PassageUserRecord {
        let user = PassageUserRecord()
        user.id = UUID().uuidString
        user.passwordHash = passwordHash
        user.emailVerified = false
        user.phoneVerified = false

        // Map identifier kind to the appropriate column.
        switch identifier.kind {
        case .email:
            user.email = identifier.value
        case .username:
            user.username = identifier.value
        case .phone:
            user.phone = identifier.value
        case .federated:
            // Federated identities don't map to a single column;
            // the identifiers table holds the provider-specific mapping.
            break
        }

        return user
    }

    /// Called after an identifier is marked verified in Passage's identifiers table.
    /// Syncs the verification state to this record's `email_verified` or `phone_verified` column.
    static func passageDidMarkIdentifierVerified(
        _ kind: Identifier.Kind,
        for user: PassageUserRecord,
        on db: any Database
    ) async throws {
        switch kind {
        case .email:
            user.emailVerified = true
        case .phone:
            user.phoneVerified = true
        case .username:
            // Username has no verification flag.
            break
        case .federated:
            // Federated identities have no verification flag.
            break
        }
        try await user.save(on: db)
    }
}

// MARK: - Passage.User Conformance (via PassageUserModel)

/// PassageUserModel already refines Passage.User, so these implementations
/// satisfy the protocol requirements.
extension PassageUserRecord {
    var isAnonymous: Bool {
        false
    }

    var isEmailVerified: Bool {
        emailVerified ?? false
    }

    var isPhoneVerified: Bool {
        phoneVerified ?? false
    }
}
