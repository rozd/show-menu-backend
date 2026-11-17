//
//  FluentTransaction.swift
//  ShowMenuBackend
//
//  The transport-erased handle threaded through `UnitOfWorkContext.transaction`.
//

import Fluent
import FluentPostgresDriver

/// A transport-erased handle over a Fluent database, threaded through
/// ``UnitOfWorkContext/transaction``.
///
/// Two modes, mirroring the two altitudes the architecture distinguishes:
///
/// - ``direct(database:)`` — reads and relay work that run *outside* any command
///   transaction (query handlers, the outbox relay). Statements auto-commit.
/// - ``transaction(database:)`` — the write path of a command. The wrapped handle
///   is the connection Fluent opened for `database.transaction { … }`, so every
///   statement issued through it joins that transaction and commits or rolls back
///   with it.
///
/// Note what is *not* here: no write buffer. A store without transactions of its
/// own would have to stage writes and apply them atomically at commit; SQL has a
/// real transaction, so "enlisting" simply means issuing statements on this
/// connection. Everything above the ``UnitOfWork`` seam is written as if the
/// buffer might exist, which is what keeps that seam meaningful.
struct FluentTransaction: Sendable {

    /// The Fluent handle every read and write goes through. Inside a command it is
    /// the transaction's connection, so statements enlist automatically.
    let database: any Database

    /// True when ``database`` is the connection of an open transaction.
    ///
    /// Carried for diagnostics and for the stores that must refuse to run outside
    /// one (the outbox's write side would silently lose its atomicity guarantee).
    let isTransactional: Bool

    private init(database: any Database, isTransactional: Bool) {
        self.database = database
        self.isTransactional = isTransactional
    }

    /// Non-transactional handle: statements auto-commit. Used by query handlers and
    /// the outbox relay, which run outside any command transaction.
    static func direct(database: any Database) -> FluentTransaction {
        FluentTransaction(database: database, isTransactional: false)
    }

    /// Transaction-bound handle, built by ``FluentUnitOfWork`` from the connection
    /// Fluent hands to `database.transaction { … }`.
    static func transaction(database: any Database) -> FluentTransaction {
        FluentTransaction(database: database, isTransactional: true)
    }

    /// The SQL layer beneath the Fluent handle.
    ///
    /// Fluent's ORM addresses tables through a bespoke `Model` class per table,
    /// which a ``DataSource`` generic over an opaque `Codable` model cannot have —
    /// so the generic data sources bind at the SQL layer instead (see
    /// ``FluentDataSource``). Every SQL driver Fluent ships for a relational store
    /// vends this; a non-SQL driver would not, hence the throw.
    var sql: any SQLDatabase {
        get throws {
            guard let sql = database as? any SQLDatabase else {
                throw FluentStoreError.notSQLDatabase(driver: String(describing: type(of: database)))
            }
            return sql
        }
    }
}
