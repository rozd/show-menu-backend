//
//  FluentDataSource+Concurrency.swift
//  ShowMenuBackend
//
//  Optimistic concurrency (check-and-set) for versioned models.
//

import Foundation
import Logging
import FluentPostgresDriver

// MARK: - Check-and-Set

/// Real check-and-set, available **only** where the model opts in by conforming to
/// ``VersionedModel``. Data sources over un-versioned models inherit
/// ``DataSource``'s no-op defaults, so versioning stays opt-in per aggregate.
///
/// The token is bound to an integer `version` column, and the compare-and-swap is
/// **one statement**:
///
/// ```sql
/// UPDATE users SET …, version = $next
///  WHERE id = $id AND version = $expected
/// RETURNING id
/// ```
///
/// Two properties matter:
///
/// 1. **No read-then-write window.** The comparison happens inside the write, so
///    there is nothing to race. A store that could only compare at read time
///    would have to re-validate at commit to close the gap; SQL does not.
/// 2. **`RETURNING` reports what actually matched.** Fluent's `QueryBuilder.update()`
///    yields `Void`, so a CAS that updated *zero* rows would be indistinguishable
///    from success — a silently lost update. Counting returned rows is what makes
///    the conflict detectable at all, and is why this path drops to SQL.
///
/// A zero-row result is then diagnosed with one follow-up read, purely to name the
/// *actual* token in the error (or to report a missing row as such).
extension FluentDataSource where Model: VersionedModel {

    /// The column holding the optimistic-concurrency counter.
    var versionColumn: String { FluentCoding.columnName(for: "version") }

    /// Insert stamping the initial token (counter `1`), so the aggregate's first
    /// update has a concrete version to match against.
    func insert(model: Model) async throws {
        let id = documentId(for: model)
        logger.debug("Inserting versioned row", metadata: [
            "table": .string(table), "id": .string(id)
        ])
        var stamped = model
        stamped.version = 1
        try await upsert(stamped)
    }

    /// Check-and-set update: one conditional statement, then the advanced token.
    ///
    /// An **absent stored counter matches `Version.none`** (`version IS NULL`), so
    /// rows written before versioning existed adopt optimistic concurrency on their
    /// first write with no data migration — the property ``Version`` documents.
    func update(model: Model, ifMatching expected: Version) async throws -> Version {
        let id = documentId(for: model)
        logger.debug("Checked update", metadata: [
            "table": .string(table), "id": .string(id),
            "expectedVersion": .string(expected.description)
        ])

        let next = try counter(of: expected, id: id) + 1
        var advanced = model
        advanced.version = next

        let returned = try await sql
            .update(table)
            .set(model: advanced, with: FluentCoding.encoder)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .where(try versionPredicate(expected, id: id))
            .returning(SQLColumn(idColumn))
            .all()

        guard returned.isEmpty == false else {
            // Nothing matched: either the row is gone, or another transaction
            // committed and moved the counter. One read tells them apart and names
            // the actual token — surfaced unchanged, never collapsed into a store
            // error, because the edge maps it to 409/412.
            guard let actual = try await storedVersion(id: id) else {
                throw FluentStoreError.notFound(table: table, id: id)
            }
            throw ConcurrencyError.versionConflict(
                entity: table, id: id, expected: expected, actual: actual
            )
        }

        return Version(next)
    }

    /// Check-and-set delete. A row that is already gone is an idempotent success.
    func delete(byId id: String, ifMatching expected: Version) async throws {
        logger.debug("Checked delete", metadata: [
            "table": .string(table), "id": .string(id),
            "expectedVersion": .string(expected.description)
        ])

        let returned = try await sql
            .delete(from: table)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .where(try versionPredicate(expected, id: id))
            .returning(SQLColumn(idColumn))
            .all()

        guard returned.isEmpty else { return }

        guard let actual = try await storedVersion(id: id) else {
            return // already gone — idempotent
        }
        throw ConcurrencyError.versionConflict(
            entity: table, id: id, expected: expected, actual: actual
        )
    }

    // MARK: Internals

    /// `version = $expected`, or `version IS NULL` for ``Version/none``.
    private func versionPredicate(_ expected: Version, id: String) throws -> any SQLExpression {
        guard expected.rawValue != nil else {
            return SQLBinaryExpression(SQLColumn(versionColumn), .is, SQLLiteral.null)
        }
        return SQLBinaryExpression(
            SQLColumn(versionColumn), .equal, SQLBind(try counter(of: expected, id: id))
        )
    }

    /// The integer behind an opaque token. `.none` counts as `0`, so a first write
    /// advances to `1`.
    private func counter(of version: Version, id: String) throws -> Int {
        guard let rawValue = version.rawValue else { return 0 }
        guard let counter = version.versionInt else {
            throw FluentStoreError.malformedVersion(table: table, id: id, token: rawValue)
        }
        return counter
    }

    /// The token currently stored for `id`, or `nil` when the row does not exist.
    ///
    /// The two "empty" answers mean different things and must not be confused: a
    /// missing row is `nil`, while a row whose counter is `NULL` is
    /// `Version.none` — spelled out below, because a bare `.none` in this position
    /// infers `Optional.none` and would report an existing row as gone (turning a
    /// conflict into a bogus "not found", and a refused delete into a silent
    /// success).
    private func storedVersion(id: String) async throws -> Version? {
        let rows = try await sql
            .select()
            .column(SQLColumn(versionColumn))
            .from(table)
            .where(SQLColumn(idColumn), .equal, SQLBind(id))
            .limit(1)
            .all()
        guard let row = rows.first else { return nil }
        guard try row.decodeNil(column: versionColumn) == false else { return Version.none }
        return Version(try row.decode(column: versionColumn, inferringAs: Int.self))
    }
}
