import Fluent

/// Adds the `roles` column to the `users` table — the authorization role names
/// resolved into `Principal.roles` at the request boundary.
///
/// Nullable on purpose: rows written before roles were introduced decode as
/// `nil`, which the mapper treats as an empty role set — the same
/// no-data-migration posture as `version`.
struct AddUserRoles: AsyncMigration {

    var name: String { "AddUserRoles" }

    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("roles", .array(of: .string))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("roles")
            .update()
    }
}
