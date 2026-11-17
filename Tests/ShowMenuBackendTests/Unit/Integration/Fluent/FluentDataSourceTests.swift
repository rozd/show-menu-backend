import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// Drives `FluentUserDataSource` over ``StubSQLDatabase`` and asserts the SQL it
/// emits and the models it decodes back — the closest thing to an end-to-end test
/// of the adapter that needs no Postgres.
@Suite("Fluent DataSource")
struct FluentDataSourceTests {

    private func makeSUT() -> (ds: FluentUserDataSource, db: StubSQLDatabase) {
        let db = StubSQLDatabase()
        let ds = FluentUserDataSource(
            transaction: .transaction(database: db),
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )
        return (ds, db)
    }

    private func row(id: String = "i1", version: Int? = 3) -> StubSQLRow {
        StubSQLRow([
            "id": id,
            "display_name": "Widget",
            "email": "widget@example.com",
            "version": version,
            "created_at": Date(timeIntervalSince1970: 1_000)
        ])
    }

    // MARK: - Fetch

    @Test("fetch(byId:) selects one row by primary key and decodes it")
    func fetchDecodesRow() async throws {
        let (ds, db) = makeSUT()
        db.enqueue(rows: [row()])

        let model = try #require(try await ds.fetch(byId: "i1"))

        #expect(model.id == "i1")
        #expect(model.displayName == "Widget")
        #expect(model.email == "widget@example.com")
        #expect(model.version == 3)
        #expect(model.createdAt == Date(timeIntervalSince1970: 1_000))

        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"FROM "users""#))
        #expect(statement.sql.contains(#""id" = $1"#))
        #expect(statement.sql.contains("LIMIT 1"))
        #expect(statement.binds == ["i1"])
    }

    @Test("fetch(byId:) returns nil when no row matches")
    func fetchMissingReturnsNil() async throws {
        let (ds, db) = makeSUT()
        db.enqueueNoRows()

        #expect(try await ds.fetch(byId: "nope") == nil)
        #expect(db.executed.count == 1)
    }

    @Test("fetch(byId:) reports an undecodable row as a store error, not as nil")
    func fetchUndecodableRowThrows() async throws {
        // A row missing a required column is a schema/migration mismatch. Surfacing
        // it beats returning nil, which reads as "no such user".
        let (ds, db) = makeSUT()
        db.enqueue(rows: [StubSQLRow(["id": "i1", "version": "not-an-int"])])

        await #expect(throws: FluentStoreError.self) {
            _ = try await ds.fetch(byId: "i1")
        }
    }

    // MARK: - Insert

    @Test("insert(model:) upserts and stamps the initial version")
    func insertUpserts() async throws {
        let (ds, db) = makeSUT()

        try await ds.insert(model: UserModel(id: "i1", displayName: "Widget", version: nil))

        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"INSERT INTO "users""#))
        // Upsert, not a plain insert: re-inserting the same aggregate id overwrites,
        // aggregate identity is the domain's business, not the store's.
        #expect(statement.sql.contains("ON CONFLICT"))
        #expect(statement.sql.contains("DO UPDATE SET"))
        // The primary key is the conflict target, so it must not be reassigned.
        #expect(statement.sql.contains(#""id" = EXCLUDED."id""#) == false)
        #expect(statement.sql.contains(#""display_name" = EXCLUDED."display_name""#))
        // `version` is stamped by the versioned insert path even though the model
        // arrived with none.
        #expect(statement.sql.contains(#""version""#))
        #expect(statement.binds.contains { $0 == "1" || $0 == "Optional(1)" })
    }

    // MARK: - Update

    @Test("update(model:) writes every column, including nils, filtered by id")
    func updateWritesAllColumns() async throws {
        let (ds, db) = makeSUT()

        try await ds.update(model: UserModel(id: "i1", email: nil, displayName: "Renamed", version: 2))

        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"UPDATE "users""#))
        #expect(statement.sql.contains(#""display_name" = $"#))
        // An explicit NULL, not an omitted column: clearing a field must actually
        // clear it (the `.asNil` encoding strategy). Omission would silently leave
        // the previous email in place.
        #expect(statement.sql.contains(#""email" = NULL"#))
        #expect(statement.sql.contains(#"WHERE "id" = $"#))
    }

    // MARK: - Delete

    @Test("delete(byIds:) issues one statement with an IN list")
    func deleteByIdsBatches() async throws {
        let (ds, db) = makeSUT()

        try await ds.delete(byIds: ["i1", "i2", "i3"])

        #expect(db.executed.count == 1)
        let statement = try #require(db.executed.first)
        #expect(statement.sql.contains(#"DELETE FROM "users""#))
        #expect(statement.sql.contains(#""id" IN ($1, $2, $3)"#))
        #expect(statement.binds == ["i1", "i2", "i3"])
    }

    @Test("delete(byIds:) with an empty list touches the database not at all")
    func deleteEmptyListEmitsNothing() async throws {
        let (ds, db) = makeSUT()

        try await ds.delete(byIds: [])

        // `DELETE … WHERE id IN ()` is a syntax error in Postgres, and deleting
        // nothing must never widen into deleting everything.
        #expect(db.executed.isEmpty)
    }
}
