import Vapor

/// Firebase Authentication event payload from Eventarc
/// Received when user.v1.created or similar events occur
struct AuthEventData: Content, Sendable {
    /// Firebase Authentication user ID
    let uid: String

    /// User's email address (if available)
    let email: String?

    /// User's display name (if available)
    let displayName: String?

    /// URL to user's profile photo (if available)
    let photoUrl: String?

    /// User's phone number (if available)
    let phoneNumber: String?

    /// Whether email has been verified
    let emailVerified: Bool?

    /// Whether the account is disabled
    let disabled: Bool?

    /// Account metadata
    let metadata: AuthMetadata?

    // Note: customClaims intentionally omitted for Phase 1
    // Can be added later with proper type handling if needed
}

// MARK: - Nested Types

extension AuthEventData {
    /// Authentication metadata for user accounts
    struct AuthMetadata: Content, Sendable {
        /// Account creation timestamp
        let createTime: String?
    }
}
