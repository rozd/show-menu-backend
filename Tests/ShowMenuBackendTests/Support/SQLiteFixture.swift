import Fluent
import FluentSQLiteDriver
import Logging
import SQLKit
import Vapor
@testable import ShowMenuBackend

/// A freshly migrated, process-local SQLite database for tests that need the
/// *real* adapter rather than a double: real transactions, real primary-key
/// violations, real `UPDATE … RETURNING` check-and-set.
///
/// This is the same driver `configureFluentStore` picks when no connection
/// details are configured, so these tests exercise exactly what `swift run Run`
/// boots on. Each call gets its own database (`.memory` generates a fresh
/// identifier), so suites need no serialization and no clean-up between tests.
///
/// - Parameters:
///   - migrations: applies the app's schema. Pass `false` for a bare database.
///   - body: receives the database handle and a logger.
func withSQLiteDatabase(
    migrations: Bool = true,
    _ body: @escaping @Sendable (any Fluent.Database, Logger) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        // `isDefault: true` only because nothing else is registered here; the app
        // itself never relies on which database is default (see `DatabaseID.app`).
        app.databases.use(.sqlite(.memory), as: .app, isDefault: true)
        if migrations {
            registerMigrations(app)
            try await app.autoMigrate()
        }
        try await body(app.db(.app), app.logger)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

// MARK: - Atomicity fixtures

/// Table names used by the idempotency/inbox atomicity suites.
enum AtomicityTables {
    static let work = "atomicity_work"
    static let parent = "atomicity_parent"
}

/// Creates the two tables the atomicity suites write through.
///
/// `atomicity_work.parent` is a **deferred** foreign key: SQLite and Postgres
/// both postpone `DEFERRABLE INITIALLY DEFERRED` checks to `COMMIT`. That is the
/// only portable way to make a transaction fail *after* every statement in it
/// has succeeded — which is exactly the window those suites need, because the
/// idempotency/inbox record is written last, and "the record was stored but the
/// commit failed" is the case that must leave nothing behind.
func createAtomicityTables(on database: any Fluent.Database) async throws {
    guard let sql = database as? any SQLDatabase else {
        fatalError("The atomicity fixtures need a SQL database")
    }
    try await sql.raw("CREATE TABLE \(unsafeRaw: AtomicityTables.parent) (id TEXT PRIMARY KEY)").run()
    try await sql.raw("""
        CREATE TABLE \(unsafeRaw: AtomicityTables.work) (
            id TEXT PRIMARY KEY,
            parent TEXT REFERENCES \(unsafeRaw: AtomicityTables.parent)(id) DEFERRABLE INITIALLY DEFERRED
        )
        """).run()
}

/// Reads a work row back through a non-transactional handle.
func atomicityWorkRowExists(id: String, on database: any Fluent.Database) async throws -> Bool {
    guard let sql = database as? any SQLDatabase else {
        fatalError("The atomicity fixtures need a SQL database")
    }
    let rows = try await sql
        .select()
        .column(SQLLiteral.all)
        .from(AtomicityTables.work)
        .where(SQLColumn("id"), .equal, SQLBind(id))
        .all()
    return rows.isEmpty == false
}

/// Writes one work row through `transaction`. A `parent` that does not exist
/// makes the *commit* fail, not this statement.
func writeAtomicityWorkRow(
    id: String,
    parent: String? = nil,
    through transaction: FluentTransaction
) async throws {
    try await transaction.sql
        .insert(into: AtomicityTables.work)
        .columns(SQLColumn("id"), SQLColumn("parent"))
        .values(SQLBind(id), SQLBind(parent))
        .run()
}
