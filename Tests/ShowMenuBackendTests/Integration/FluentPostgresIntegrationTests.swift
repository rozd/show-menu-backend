import Foundation
import Testing
import Logging
import Vapor
import Fluent
import FluentPostgresDriver
@testable import ShowMenuBackend

/// Acceptance tests for the Fluent adapter against a **real Postgres**.
///
/// Skipped unless `POSTGRES_TEST_URL` is set, so `swift test` still needs zero
/// infrastructure:
///
/// ```bash
/// docker compose --profile postgres up -d db
/// POSTGRES_TEST_URL=postgres://vapor:vapor@localhost:5432/vapor swift test
/// ```
///
/// **What lives here vs. in `FluentSQLiteIntegrationTests`.** The behavioural
/// guarantees — CAS semantics, outbox atomicity, the uniqueness guards — are
/// dialect-neutral and are proved by the SQLite suite, which every `swift test`
/// run executes. This suite exists for what SQLite cannot answer:
///
/// - **Postgres accepts the emitted SQL.** Every construct the adapter reaches
///   for (`ON CONFLICT … DO UPDATE`, `UPDATE … RETURNING`, pushed-down filters, a native `text[]` column) has to run on *this* dialect
///   too, and only a real server can say so.
/// - **A genuine concurrent race.** SQLite serializes writers, so "two writers at
///   once" there proves nothing about check-and-set.
///
/// The suite is serialized because every test shares one schema.
///
/// > Warning: it drops and recreates the app's tables. Point it at a scratch
/// > database, never at anything you care about.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] != nil),
    .serialized
)
struct FluentPostgresIntegrationTests {

    // MARK: - Harness

    /// Boots an `Application` wired to the test database with a freshly migrated
    /// schema, runs `body`, then tears everything down.
    private func withDatabase(
        _ body: @escaping @Sendable (any Fluent.Database, Logger) async throws -> Void
    ) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"])
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.postgres(configuration: try SQLPostgresConfiguration(url: url)), as: .psql)
            app.migrations.add(CreateOutbox())
            app.migrations.add(CreateIdempotencyKeys())
            app.migrations.add(CreateInbox())
            app.migrations.add(CreateUsers())
            app.migrations.add(AddUserRoles())

            // Start from a known-empty schema; a leftover table from a failed run
            // would otherwise make the next one fail for the wrong reason.
            try? await app.autoRevert()
            try await app.autoMigrate()

            try await body(app.db, app.logger)

            try await app.autoRevert()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func dataSource(_ db: any Fluent.Database, _ logger: Logger) -> FluentUserDataSource {
        FluentUserDataSource(transaction: .direct(database: db), logger: logger)
    }

    private func item(id: String, name: String = "Widget", version: Int? = nil) -> UserModel {
        UserModel(id: id, displayName: name, version: version, createdAt: Date())
    }

    // MARK: - Schema and round trip

    @Test("migrations apply and an inserted row reads back")
    func insertFetchRoundTrip() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "Widget"))

            let fetched = try #require(try await ds.fetch(byId: "i1"))
            #expect(fetched.displayName == "Widget")
            // The versioned insert path stamps the initial token.
            #expect(fetched.version == 1)
        }
    }

    @Test("an upserted row overwrites rather than violating the primary key")
    func insertIsUpsert() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "First"))
            try await ds.insert(model: self.item(id: "i1", name: "Second"))

            #expect(try await ds.fetch(byId: "i1")?.displayName == "Second")
        }
    }

    @Test("filters, ordering and limit are honoured by the database")
    func queryPushdown() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "a", name: "Alpha"))
            try await ds.insert(model: self.item(id: "b", name: "Beta"))
            try await ds.insert(model: self.item(id: "c", name: "Beta"))

            let matches = try await ds.query(DataSourceQuery(
                filters: [DataSourceFilter(field: "displayName", op: .equal, value: "Beta")],
                orders: [DataSourceOrder(field: "id", direction: .descending)]
            ))
            #expect(matches.items.map(\.id) == ["c", "b"])

            let limited = try await ds.query(DataSourceQuery(limit: 2))
            #expect(limited.items.count == 2)

            let inList = try await ds.query(DataSourceQuery(
                filters: [DataSourceFilter(field: "id", op: .in, value: ["a", "c"])]
            ))
            #expect(Set(inList.items.map(\.id)) == ["a", "c"])
        }
    }

    /// `AddUserRoles` becomes a native `text[]` here and a JSON text column on
    /// SQLite. Both must round-trip the same `[String]?`.
    @Test("a native array column round-trips the roles list")
    func nativeArrayColumn() async throws {
        try await withDatabase { db, logger in
            let ds = FluentUserDataSource(transaction: .direct(database: db), logger: logger)
            try await ds.insert(model: UserModel(id: "u1", email: "u1@example.com", roles: ["admin", "auditor"]))

            let fetched = try #require(try await ds.fetch(byId: "u1"))
            #expect(fetched.roles == ["admin", "auditor"])
        }
    }

    // MARK: - Optimistic concurrency

    /// The one CAS property SQLite genuinely cannot demonstrate: it serializes
    /// writers, so a "concurrent" conflict there is just a sequential one. Here
    /// both writers load the same token and update at the same time, and the
    /// single-statement `UPDATE … WHERE version = $expected RETURNING id` must
    /// let exactly one through.
    @Test("two writers racing on one row: exactly one wins")
    func checkAndSetSurvivesAConcurrentRace() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "Original"))
            let token = Version(1)

            let outcomes = await withTaskGroup(of: (any Error)?.self) { group in
                for name in ["A", "B"] {
                    group.addTask {
                        do {
                            _ = try await ds.update(model: self.item(id: "i1", name: name), ifMatching: token)
                            return nil
                        } catch {
                            return error
                        }
                    }
                }
                return await group.reduce(into: [(any Error)?]()) { $0.append($1) }
            }

            #expect(outcomes.filter { $0 == nil }.count == 1, "exactly one writer may advance the token")
            for error in outcomes.compactMap({ $0 }) {
                #expect(error is ConcurrencyError, "the loser must see a conflict, not a store error")
            }
            let stored = try await ds.fetch(byId: "i1")
            #expect(stored?.version == 2)
        }
    }

    @Test("two writers on one row: the stale one is rejected, the row keeps the winner's value")
    func checkAndSetDetectsARealConflict() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "Original"))

            // Both writers loaded version 1.
            let loaded = try #require(try await ds.fetch(byId: "i1"))
            let token = Version(versionInt: loaded.version)

            let advanced = try await ds.update(model: self.item(id: "i1", name: "Winner"), ifMatching: token)
            #expect(advanced == Version(2))

            await #expect {
                _ = try await ds.update(model: self.item(id: "i1", name: "Loser"), ifMatching: token)
            } throws: { error in
                guard case let ConcurrencyError.versionConflict(_, _, expected, actual) = error else { return false }
                return expected == token && actual == Version(2)
            }

            // The loser must not have written anything.
            #expect(try await ds.fetch(byId: "i1")?.displayName == "Winner")
        }
    }

    @Test("a delete with a stale token leaves the row in place")
    func checkAndSetDeleteRejectsStaleToken() async throws {
        try await withDatabase { db, logger in
            let ds = self.dataSource(db, logger)
            try await ds.insert(model: self.item(id: "i1"))

            await #expect(throws: ConcurrencyError.self) {
                try await ds.delete(byId: "i1", ifMatching: Version(99))
            }
            #expect(try await ds.fetch(byId: "i1") != nil)

            try await ds.delete(byId: "i1", ifMatching: Version(1))
            #expect(try await ds.fetch(byId: "i1") == nil)
        }
    }

    // MARK: - Outbox atomicity

    @Test("an outbox row committed with its state change is visible to the relay")
    func outboxCommitsWithTheStateChange() async throws {
        try await withDatabase { db, logger in
            let unitOfWork = FluentUnitOfWork(
                database: db,
                dispatcher: SpyDomainEventDispatcher(),
                outbox: Outbox(),
                logger: logger
            )

            try await unitOfWork.execute { ctx in
                let ds = FluentUserDataSource(transaction: ctx.transaction, logger: logger)
                try await ds.insert(model: self.item(id: "i1"))
                try await ctx.outbox.record(UserCreatedIntegrationEvent(userId: "u1", email: "u1@example.com", displayName: "User One"))
            }

            let relayStore = FluentOutboxStore(transaction: .direct(database: db), logger: logger)
            let pending = try await relayStore.pending(limit: 10, now: Date())
            #expect(pending.count == 1)
            #expect(try await self.dataSource(db, logger).fetch(byId: "i1") != nil)
        }
    }

    @Test("a rolled-back transaction leaves neither the state change nor the outbox row")
    func outboxRollsBackWithTheStateChange() async throws {
        struct Boom: Error {}

        try await withDatabase { db, logger in
            let unitOfWork = FluentUnitOfWork(
                database: db,
                dispatcher: SpyDomainEventDispatcher(),
                outbox: Outbox(),
                logger: logger
            )

            await #expect(throws: Boom.self) {
                try await unitOfWork.execute { ctx in
                    let ds = FluentUserDataSource(transaction: ctx.transaction, logger: logger)
                    try await ds.insert(model: self.item(id: "i1"))
                    try await ctx.outbox.record(UserCreatedIntegrationEvent(userId: "u1", email: "u1@example.com", displayName: "User One"))
                    throw Boom()
                }
            }

            // This is the guarantee the whole pattern rests on: no committed state
            // without its event, and no event without its state.
            let relayStore = FluentOutboxStore(transaction: .direct(database: db), logger: logger)
            let pending = try await relayStore.pending(limit: 10, now: Date())
            let item = try await self.dataSource(db, logger).fetch(byId: "i1")
            #expect(pending.isEmpty)
            #expect(item == nil)
        }
    }

    @Test("the relay marks a message published and prunes it past retention")
    func relayMarksAndPrunes() async throws {
        try await withDatabase { db, logger in
            let store = FluentOutboxStore(transaction: .direct(database: db), logger: logger)
            let message = try OutboxMessage.pending(
                from: UserCreatedIntegrationEvent(userId: "u1", email: "u1@example.com", displayName: "User One"),
                sequence: 0,
                at: Date(timeIntervalSince1970: 1_000),
                coder: JSONIntegrationEventCoder()
            )
            try await store.append(message)

            try await store.markPublished(id: message.id, at: Date(timeIntervalSince1970: 2_000))
            #expect(try await store.pending(limit: 10, now: Date()).isEmpty)

            let deleted = try await store.deletePublished(publishedBefore: Date(timeIntervalSince1970: 3_000), limit: 10)
            #expect(deleted == 1)
        }
    }

    // MARK: - Idempotency

    @Test("a second record for the same key violates the primary key")
    func idempotencyKeyIsUnique() async throws {
        try await withDatabase { db, logger in
            let store = FluentIdempotencyStore(
                transaction: .direct(database: db),
                ttl: 3600,
                logger: logger
            )
            let fingerprint = try RequestFingerprint(payload: ["name": "Widget"])
            let ticket = IdempotencyTicket(id: "key-1", fingerprint: fingerprint, overwriteExpired: false)
            let response = StoredResponse(status: 201, body: Data("{}".utf8))

            try await store.complete(ticket: ticket, response: response)

            // The uniqueness constraint *is* the in-flight guard: a concurrent
            // duplicate cannot also commit.
            await #expect(throws: IdempotencyError.self) {
                try await store.complete(ticket: ticket, response: response)
            }

            guard case let .replay(stored) = try await store.reserve(id: "key-1", fingerprint: fingerprint) else {
                Issue.record("A committed record must replay rather than re-run the work")
                return
            }
            #expect(stored.status == 201)
        }
    }

    // MARK: - Inbox

    @Test("a second record for the same event violates the primary key")
    func inboxEventIdIsUnique() async throws {
        try await withDatabase { db, logger in
            let store = FluentInboxStore(
                transaction: .direct(database: db),
                ttl: 7 * 24 * 3600,
                logger: logger
            )
            let ticket = InboxTicket(id: "inbox-1", overwriteExpired: false)

            try await store.complete(ticket: ticket)

            // The uniqueness constraint *is* the in-flight guard: a concurrent
            // duplicate cannot also commit.
            await #expect(throws: InboxError.self) {
                try await store.complete(ticket: ticket)
            }

            guard case .alreadyProcessed = try await store.reserve(id: "inbox-1") else {
                Issue.record("A committed record must report already-processed rather than proceed")
                return
            }
        }
    }
}
