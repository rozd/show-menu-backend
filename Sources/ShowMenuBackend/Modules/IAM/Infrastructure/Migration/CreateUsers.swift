import Fluent
import FluentPostgresDriver

/// Creates the `users` table backing ``FluentUserDataSource``.
///
/// Columns are the `snake_case` form of ``UserModel``'s coding keys. Note
/// `photo_url`: the model deliberately spells that key `photoUrl` rather than
/// `photoURL`, because the camelCase→snake_case transform splits on lower→upper
/// boundaries and an acronym run would not fold the way you expect (see
/// ``FluentCoding/columnName(for:)``).
///
/// `email` and `display_name` carry indexes — `FindUserQuery` filters on both.
struct CreateUsers: AsyncMigration {

    var name: String { "CreateUsers" }

    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("id", .string, .identifier(auto: false))
            .field("email", .string)
            .field("phone", .string)
            .field("username", .string)
            .field("display_name", .string)
            .field("photo_url", .string)
            .field("email_verified", .bool)
            .field("phone_verified", .bool)
            .field("disabled", .bool)
            .field("version", .int)
            .field("created_at", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.create(index: "users_email_idx").on("users").column("email").run()
        try await sql.create(index: "users_display_name_idx").on("users").column("display_name").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users").delete()
    }
}
