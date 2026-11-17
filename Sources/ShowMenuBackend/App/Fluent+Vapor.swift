//
//  Fluent+Vapor.swift
//  ShowMenuBackend
//
//  App wiring for the Fluent/Postgres store adapter.
//

import Vapor
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import NIOSSL

// MARK: - Database identifier

extension DatabaseID {

    /// The app's own aggregate store — users, outbox, idempotency, inbox.
    ///
    /// Deliberately **not** Fluent's default database: `appDatabase` always
    /// resolves it explicitly by this identifier, so nothing depends on which
    /// database Fluent considers "default" — a stable seam for a project that
    /// later registers a second database (see **The extension point** in
    /// DEVELOPER_NOTES.md).
    static var app: DatabaseID { .init(string: "app") }
}

// MARK: - Configuration

/// Wires the Fluent adapter (`Integration/Fluent/`): registers the app database
/// under ``DatabaseID/app``, registers the migrations and (optionally) runs them.
///
/// **Which SQL dialect** is the one thing here the environment does decide, and
/// only because both are the same adapter: connection details present →
/// Postgres; nothing set → an in-memory SQLite database, so `swift run Run` and
/// `swift test` need no infrastructure at all. In the **production** environment
/// nothing set is a startup error (``StoreConfigurationError/missingProductionDatabase``). Everything above the `DataSource`
/// seam is identical either way, and hand-written SQL is expected to stay in the
/// SQLite ∩ Postgres subset (see `Integration/Fluent/README.md`).
///
/// Must run **before** anything touches `app.deps`, because the composition root
/// resolves `app.db(.app)` when it builds the store.
///
/// Environment:
///
/// | Variable | Meaning |
/// |---|---|
/// | `DATABASE_URL` | Full Postgres connection URL |
/// | `DATABASE_HOST` / `_PORT` / `_USERNAME` / `_PASSWORD` / `_NAME` | Postgres connection details, used when no URL is given |
/// | `DATABASE_AUTO_MIGRATE` | `true` (default) runs pending migrations at boot; set `false` to run `swift run Run migrate` yourself |
func configureFluentStore(_ app: Application) async throws {
    let driver = try FluentDriver.resolve(environment: app.environment)
    // Never the default database — see `DatabaseID.app` for why.
    app.databases.use(driver.configuration, as: .app, isDefault: false)
    registerMigrations(app)

    // A Fluent model's table name is static, so a relocated outbox collection
    // would read and write different tables. Fail at startup, loudly.
    guard app.deps.outbox.collection == OutboxMessageRecord.schema else {
        throw StoreConfigurationError.outboxTableMismatch(
            configured: app.deps.outbox.collection,
            required: OutboxMessageRecord.schema
        )
    }

    if autoMigrateEnabled() {
        app.logger.info("Running pending migrations")
        try await app.autoMigrate()
    }

    switch driver {
    case let .postgres(configuration):
        app.logger.info("Store: postgres (Fluent)", metadata: [
            "database": .string(configuration.coreConfiguration.database ?? "<default>")
        ])
    case .sqliteInMemory:
        app.logger.warning("Store: in-memory SQLite (non-durable — all data is lost on restart); set DATABASE_URL to run on Postgres")
    }
}

// MARK: - Driver selection

/// The SQL dialect the Fluent adapter runs on.
///
/// Not a second *adapter* — `Integration/Fluent/` is one binding and both cases
/// go through it. The distinction exists only to keep the zero-infrastructure
/// boot honest: an operator must never mistake the ephemeral SQLite database for
/// a deployment, so it is announced as a warning and chosen only when nothing
/// else is configured.
enum FluentDriver: Sendable {

    case postgres(SQLPostgresConfiguration)

    /// A fresh, process-local SQLite database. The zero-configuration default.
    case sqliteInMemory

    /// Postgres when connection details are present, SQLite otherwise — except in
    /// `.production`, where the missing configuration is a boot failure rather
    /// than a silent fall back to a throwaway database.
    ///
    /// - Parameters:
    ///   - values: The variable source; injectable for tests.
    ///   - environment: The Vapor environment the app runs in.
    static func resolve(
        values: [String: String] = ProcessInfo.processInfo.environment,
        environment: Vapor.Environment
    ) throws -> FluentDriver {
        func value(_ key: String) -> String? {
            values[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        if let url = value("DATABASE_URL") {
            return .postgres(try SQLPostgresConfiguration(url: url))
        }
        guard let host = value("DATABASE_HOST") else {
            if environment == .production {
                throw StoreConfigurationError.missingProductionDatabase
            }
            return .sqliteInMemory
        }
        // Host given but no username: half-configured. Fail loudly at startup
        // rather than silently falling back to a throwaway database.
        guard let username = value("DATABASE_USERNAME") else {
            throw StoreConfigurationError.missingConnectionDetails
        }
        return .postgres(SQLPostgresConfiguration(
            hostname: host,
            port: value("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: username,
            password: values["DATABASE_PASSWORD"],
            database: values["DATABASE_NAME"],
            tls: .prefer(try .init(configuration: .clientDefault))
        ))
    }

    var configuration: DatabaseConfigurationFactory {
        switch self {
        case let .postgres(configuration):
            .postgres(configuration: configuration)
        case .sqliteInMemory:
            .sqlite(.memory)
        }
    }
}

/// Every migration the app owns, in dependency order.
///
/// Adapter-owned tables first (outbox, idempotency, inbox), then one per module — the same
/// split the `Integration/` vs `Modules/` layering draws everywhere else.
func registerMigrations(_ app: Application) {
    app.migrations.add(CreateOutbox(), to: .app)
    app.migrations.add(CreateIdempotencyKeys(), to: .app)
    app.migrations.add(CreateInbox(), to: .app)
    app.migrations.add(CreateUsers(), to: .app)
    app.migrations.add(AddUserRoles(), to: .app)
}

func autoMigrateEnabled() -> Bool {
    guard let raw = Environment.get("DATABASE_AUTO_MIGRATE")?.lowercased() else {
        return true
    }
    return !["false", "0", "no"].contains(raw)
}
