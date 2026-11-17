import Fluent

/// Migration to add Passage's credential column to the shared `users` table.
///
/// Only `password_hash` (nullable — bcrypt hash, or NULL for passwordless auth)
/// is Passage-exclusive; the identity columns (`phone`, `username`,
/// `phone_verified`) belong to the IAM `User` aggregate and live in the base
/// `CreateUsers` migration.
///
/// The column is owned by Passage and never written by the IAM module. The
/// revert drops exactly it, restoring the IAM-only shape of the table — run it
/// (or drop the column by hand) when removing Passage.
struct AddUserAuthColumns: AsyncMigration {
    var name: String { "Passage.AddUserAuthColumns" }

    func prepare(on database: any Database) async throws {
        // One schema update per column: SQLite accepts a single ADD COLUMN per
        // ALTER TABLE, so a batched update would fail on the default driver.
        try await database.schema("users").field("password_hash", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users").deleteField("password_hash").update()
    }
}
