import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// The Fluent adapter's optimistic concurrency: one conditional statement, with
/// `RETURNING` making a failed check-and-set *detectable*.
///
/// The scripted responses matter as much as the assertions — a CAS emits the
/// conditional write first and, only if it matched nothing, a follow-up read to
/// find out what the actual token is. Queueing "no rows, then a row" is how a real
/// conflict is reproduced without a second connection.
@Suite("Fluent Concurrency")
struct FluentConcurrencyTests {

    private func makeSUT() -> (ds: FluentUserDataSource, db: StubSQLDatabase) {
        let db = StubSQLDatabase()
        let ds = FluentUserDataSource(
            transaction: .transaction(database: db),
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
        return (ds, db)
    }

    private func model(version: Int?) -> UserModel {
        UserModel(id: "i1", displayName: "Widget", version: version)
    }

    // MARK: - Update

    @Test("a matching update is one conditional statement and advances the token")
    func updateAdvancesVersion() async throws {
        let (ds, db) = makeSUT()
        db.enqueue(rows: [StubSQLRow(["id": "i1"])])   // the UPDATE matched one row

        let advanced = try await ds.update(model: model(version: 3), ifMatching: Version(3))

        #expect(advanced == Version(4))
        #expect(db.executed.count == 1, "a successful CAS needs no follow-up read")

        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"UPDATE "users""#))
        #expect(statement.sql.contains(#""version" = $"#))
        #expect(statement.sql.contains(#"WHERE "id" = $"#))
        // The comparison lives *inside* the write — that is what leaves no window
        // to race.
        #expect(statement.sql.contains(#"AND "version" = $"#))
        // Without RETURNING there is no way to tell a matched update from a missed
        // one, and a lost update would report success.
        #expect(statement.sql.contains(#"RETURNING "id""#))
    }

    @Test("an update that matches nothing reports the conflict with the actual token")
    func updateConflictReportsActualVersion() async throws {
        let (ds, db) = makeSUT()
        db.enqueueNoRows()                                   // CAS matched nothing…
        db.enqueue(rows: [StubSQLRow(["version": 7])])       // …the row is at 7

        await #expect {
            _ = try await ds.update(model: model(version: 3), ifMatching: Version(3))
        } throws: { error in
            guard case let ConcurrencyError.versionConflict(entity, id, expected, actual) = error else {
                return false
            }
            return entity == "users" && id == "i1" && expected == Version(3) && actual == Version(7)
        }
        #expect(db.executed.count == 2, "a failed CAS costs exactly one diagnostic read")
    }

    @Test("an update of a row that no longer exists is reported as not found")
    func updateMissingRowThrowsNotFound() async throws {
        let (ds, db) = makeSUT()
        db.enqueueNoRows()   // CAS matched nothing
        db.enqueueNoRows()   // …and the row is gone entirely

        await #expect(throws: FluentStoreError.self) {
            _ = try await ds.update(model: model(version: 3), ifMatching: Version(3))
        }
    }

    @Test("Version.none binds as IS NULL, so pre-versioning rows adopt CAS on first write")
    func updateWithNoneMatchesNullVersion() async throws {
        let (ds, db) = makeSUT()
        db.enqueue(rows: [StubSQLRow(["id": "i1"])])

        let advanced = try await ds.update(model: model(version: nil), ifMatching: .none)

        #expect(advanced == Version(1))
        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#""version" IS NULL"#))
    }

    @Test("a row whose counter is NULL is a conflict, not a missing row")
    func updateAgainstNullCounterReportsConflict() async throws {
        // A row that predates versioning exists but holds no counter. That is
        // `Version.none`, *not* "no such row" — confusing the two would report a
        // stale write as `notFound`.
        let (ds, db) = makeSUT()
        db.enqueueNoRows()                                      // CAS matched nothing
        db.enqueue(rows: [StubSQLRow(["version": Int?.none])])  // …the row is there, counter NULL

        await #expect {
            _ = try await ds.update(model: model(version: 3), ifMatching: Version(3))
        } throws: { error in
            guard case let ConcurrencyError.versionConflict(_, _, expected, actual) = error else { return false }
            return expected == Version(3) && actual == .none
        }
    }

    @Test("a delete refused against a NULL counter does not report success")
    func deleteAgainstNullCounterReportsConflict() async throws {
        // The dangerous half of the same bug: reporting "already gone" for a row
        // that is still there means a delete silently did nothing.
        let (ds, db) = makeSUT()
        db.enqueueNoRows()
        db.enqueue(rows: [StubSQLRow(["version": Int?.none])])

        await #expect(throws: ConcurrencyError.self) {
            try await ds.delete(byId: "i1", ifMatching: Version(3))
        }
    }

    @Test("a non-integer token is rejected as malformed rather than silently matching")
    func updateWithMalformedTokenThrows() async throws {
        let (ds, _) = makeSUT()

        await #expect(throws: FluentStoreError.self) {
            _ = try await ds.update(model: model(version: 3), ifMatching: Version(rawValue: "etag-abc"))
        }
    }

    // MARK: - Delete

    @Test("a matching delete is one conditional statement")
    func deleteMatching() async throws {
        let (ds, db) = makeSUT()
        db.enqueue(rows: [StubSQLRow(["id": "i1"])])

        try await ds.delete(byId: "i1", ifMatching: Version(3))

        #expect(db.executed.count == 1)
        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"DELETE FROM "users""#))
        #expect(statement.sql.contains(#"AND "version" = $"#))
        #expect(statement.sql.contains(#"RETURNING "id""#))
    }

    @Test("deleting a row that is already gone is an idempotent success")
    func deleteAlreadyGoneSucceeds() async throws {
        let (ds, db) = makeSUT()
        db.enqueueNoRows()   // DELETE matched nothing
        db.enqueueNoRows()   // …because the row does not exist

        try await ds.delete(byId: "i1", ifMatching: Version(3))
    }

    @Test("deleting a row whose token moved is a conflict, not a silent no-op")
    func deleteStaleTokenConflicts() async throws {
        let (ds, db) = makeSUT()
        db.enqueueNoRows()                                 // DELETE matched nothing
        db.enqueue(rows: [StubSQLRow(["version": 9])])     // …the row moved on

        await #expect {
            try await ds.delete(byId: "i1", ifMatching: Version(3))
        } throws: { error in
            guard case let ConcurrencyError.versionConflict(_, _, expected, actual) = error else {
                return false
            }
            return expected == Version(3) && actual == Version(9)
        }
    }
}
