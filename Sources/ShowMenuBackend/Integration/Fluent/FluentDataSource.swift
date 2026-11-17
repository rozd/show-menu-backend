//
//  FluentDataSource.swift
//  ShowMenuBackend
//
//  The Fluent binding of the DataSource port.
//

import Foundation
import Logging
import FluentPostgresDriver

/// ``DataSource`` binding over a Fluent-managed SQL store.
///
/// A concrete data source declares *which table* its rows live in and *how* a
/// model addresses itself (`documentId(for:)`); every CRUD method arrives as a
/// default implementation below, so a module's `<Aggregate>DataSource` stays a
/// handful of stored properties.
///
/// **Why this binds at the SQL layer rather than through Fluent's ORM.** A
/// `FluentKit.Model` is a bespoke class per table, with its columns spelled out as
/// property wrappers. The ``DataSource`` port is generic over an *opaque*
/// `Codable` model, so an ORM binding would need a second, hand-written record
/// class (and a mapper) for every aggregate — and would still not be able to build
/// a `SET` clause generically, because the API that collects a model's pending
/// column values is not public. SQLKit — the layer Fluent is built on, reachable
/// from any SQL-backed Fluent handle — encodes any `Encodable` straight into
/// columns, so the store model *is* the row and no per-aggregate code is needed.
/// Fluent still owns everything around it: the connection pool, migrations, and
/// the transaction this data source enlists in.
///
/// All I/O goes through ``FluentTransaction``, so the *same* conformance serves a
/// command's transaction and a direct (query/relay) read without knowing which it
/// got.
protocol FluentDataSource<Model>: QueryableDataSource where Model: Codable & Sendable {

    /// The transaction handle this data source reads and writes through.
    var transaction: FluentTransaction { get }

    /// The table holding this data source's rows.
    ///
    /// No path prefix: a table name is fixed by its migration, and SQL namespaces
    /// with a database or schema (set in the connection URL), not with a path
    /// space. That is why `DataSourceFactory`'s `prefix` argument is ignored here.
    var table: String { get }

    /// Logger for data-access operations.
    var logger: Logger { get }

    /// Extracts the row's primary key from the model.
    func documentId(for model: Model) -> String
}

// MARK: - Default Implementation

extension FluentDataSource {

    /// The primary-key column. Fixed, matching the `id` coding key every store
    /// model in this app carries.
    var idColumn: String { "id" }

    var sql: any SQLDatabase {
        get throws { try transaction.sql }
    }

    // MARK: Reads

    func fetch(byId id: String) async throws -> Model? {
        logger.debug("Fetching row", metadata: [
            "table": .string(table), "id": .string(id)
        ])
        let rows = try await sql
            .select()
            .column(SQLLiteral.all)
            .from(table)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .limit(1)
            .all()
        guard let row = rows.first else {
            return nil
        }
        return try FluentCoding.decode(Model.self, from: row, table: table, id: id)
    }

    // MARK: Writes

    /// Unconditional upsert (`INSERT … ON CONFLICT (id) DO UPDATE`): aggregate
    /// identity is the domain's business, so re-inserting the same id overwrites
    /// rather than failing. The uniqueness
    /// precondition is reserved for the idempotency store's in-flight guard, which
    /// uses a plain `INSERT` and lets the constraint fire.
    func insert(model: Model) async throws {
        let id = documentId(for: model)
        logger.debug("Inserting row", metadata: [
            "table": .string(table), "id": .string(id)
        ])
        try await upsert(model)
    }

    func insert(models: [Model]) async throws {
        logger.debug("Inserting rows", metadata: [
            "table": .string(table), "count": .string(String(models.count))
        ])
        for model in models {
            try await insert(model: model)
        }
    }

    func update(model: Model) async throws {
        let id = documentId(for: model)
        logger.debug("Updating row", metadata: [
            "table": .string(table), "id": .string(id)
        ])
        try await sql
            .update(table)
            .set(model: model, with: FluentCoding.encoder)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .run()
    }

    func update(models: [Model]) async throws {
        logger.debug("Updating rows", metadata: [
            "table": .string(table), "count": .string(String(models.count))
        ])
        for model in models {
            try await update(model: model)
        }
    }

    func delete(byId id: String) async throws {
        logger.debug("Deleting row", metadata: [
            "table": .string(table), "id": .string(id)
        ])
        try await sql
            .delete(from: table)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .run()
    }

    func delete(byIds ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        logger.debug("Deleting rows", metadata: [
            "table": .string(table), "count": .string(String(ids.count))
        ])
        try await sql
            .delete(from: table)
            .where(SQLColumn(idColumn), .in, SQLBind.group(ids))
            .run()
    }

    // MARK: Internals

    /// `INSERT … ON CONFLICT (id) DO UPDATE SET col = EXCLUDED.col, …`.
    ///
    /// The column list comes from encoding the model, so this stays generic over
    /// any store model without naming a single field.
    func upsert(_ model: Model) async throws {
        let pairs = try FluentCoding.columns(of: model)
        let idColumn = self.idColumn
        try await sql
            .insert(into: table)
            .columns(pairs.map { SQLColumn($0.0) })
            .values(pairs.map(\.1))
            .onConflict(with: [idColumn]) { conflict in
                pairs
                    .filter { $0.0 != idColumn }
                    .reduce(conflict) { $0.set(excludedValueOf: $1.0) }
            }
            .run()
    }
}
