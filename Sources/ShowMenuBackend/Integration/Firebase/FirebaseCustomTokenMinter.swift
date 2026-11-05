import Foundation

/// Mints a Firebase Custom Token for the given subject (`uid`).
///
/// This is the infrastructure-level contract: it speaks only in terms of a plain
/// `uid` string and carries no dependency on application or domain types. Concrete
/// implementations differ per runtime environment (service account JSON signing,
/// Cloud Run IAM `signBlob`, or the unsigned Firebase Auth emulator token).
///
/// Application modules should not depend on this directly — they depend on their own
/// domain-facing port (e.g. a module's own `CustomTokenMinter` protocol) and adapt
/// to this contract via a thin adapter.
protocol FirebaseCustomTokenMinter: Sendable {
    func createCustomToken(uid: String) async throws -> String
}
