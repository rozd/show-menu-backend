import Foundation

/// Read-side view of `accounts/{accountId}`.
///
/// Accounts are **created by the client** (Flutter writes `{name, creator, ...}`
/// straight to Firestore); the backend never writes the document, it only reads it
/// to react to its creation. So this is a plain value, not an `AggregateRoot`.
struct Account: Sendable, Equatable {
    let id: String
    let name: String?
    /// Uid of the user who created the account (`creator` field).
    let creator: String
}
