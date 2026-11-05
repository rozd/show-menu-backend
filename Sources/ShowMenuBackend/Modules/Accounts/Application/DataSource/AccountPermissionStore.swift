import Foundation

/// Writes `accounts/{accountId}/permissions/{uid}` documents.
///
/// Not a `DataSource<Model>`: the permission document has no id field (its id is
/// the grantee's uid, and Node's shape is exactly `{role, permissions}`).
protocol AccountPermissionStore: Sendable {

    /// Upserts the permission document. Overwrites (Node used `set`), so a second
    /// grant — or one racing a Node-created document — is harmless.
    func put(_ permission: AccountPermissionModel, accountId: String, userId: String) async throws

    /// Reads the permission document, `nil` when the user has none. A read, so it
    /// must run before the unit of work's first write.
    func fetch(accountId: String, userId: String) async throws -> AccountPermissionModel?
}
