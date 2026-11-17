import Foundation
import Testing
import Logging
import Fluent
@testable import ShowMenuBackend

/// Acceptance tests for the Fluent adapter against a **real SQLite** database —
/// the driver `configureFluentStore` selects when nothing is configured, so this
/// suite covers the shipped zero-infrastructure path and needs no services.
///
/// What it proves that a stubbed database cannot: the migrations are *accepted*
/// by the dialect, the emitted SQL runs, and the `UPDATE … RETURNING`
/// check-and-set really detects a stale token (SQLite gained `RETURNING` in
/// 3.35 — this suite is also the assertion that the toolchain's libsqlite has it).
///
/// True concurrent races stay in `FluentPostgresIntegrationTests`: SQLite is a
/// single-writer store, so a "two writers at once" test there would prove
/// nothing about the CAS.
struct FluentSQLiteIntegrationTests {

    private func items(_ db: any Fluent.Database, _ logger: Logger) -> FluentUserDataSource {
        FluentUserDataSource(transaction: .direct(database: db), logger: logger)
    }

    private func item(id: String, name: String = "Widget", version: Int? = nil) -> UserModel {
        UserModel(id: id, displayName: name, version: version, createdAt: Date())
    }

    // MARK: - Schema and round trip

    @Test("migrations apply and an inserted row reads back")
    func insertFetchRoundTrip() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = self.items(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "Widget"))

            let fetched = try #require(try await ds.fetch(byId: "i1"))
            #expect(fetched.displayName == "Widget")
            // The versioned insert path stamps the initial token.
            #expect(fetched.version == 1)
        }
    }

    @Test("an upserted row overwrites rather than violating the primary key")
    func insertIsUpsert() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = self.items(db, logger)
            try await ds.insert(model: self.item(id: "i1", name: "First"))
            try await ds.insert(model: self.item(id: "i1", name: "Second"))

            #expect(try await ds.fetch(byId: "i1")?.displayName == "Second")
        }
    }

    @Test("filters, ordering and limit are honoured by the database")
    func queryPushdown() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = self.items(db, logger)
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

    // MARK: - Users (the array-column case)

    /// `AddUserRoles` declares `.array(of: .string)`. Postgres gets a native
    /// `text[]`; SQLite has no array type and the driver stores JSON text. This
    /// asserts the round trip survives either way — the one place the two
    /// dialects could quietly disagree about a column's shape.
    @Test("a user with roles round-trips through the array column")
    func userRolesRoundTrip() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = FluentUserDataSource(transaction: .direct(database: db), logger: logger)
            try await ds.insert(model: UserModel(
                id: "u1",
                email: "u1@example.com",
                displayName: "User One",
                roles: ["admin", "auditor"]
            ))

            let fetched = try #require(try await ds.fetch(byId: "u1"))
            #expect(fetched.email == "u1@example.com")
            #expect(fetched.roles == ["admin", "auditor"])
        }
    }

    @Test("an absent roles column decodes as nil rather than failing")
    func userWithoutRoles() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = FluentUserDataSource(transaction: .direct(database: db), logger: logger)
            try await ds.insert(model: UserModel(id: "u1", email: "u1@example.com"))

            let fetched = try #require(try await ds.fetch(byId: "u1"))
            #expect(fetched.roles == nil)
        }
    }

    // MARK: - Optimistic concurrency

    @Test("a stale token is rejected and the row keeps the winner's value")
    func checkAndSetDetectsAConflict() async throws {
        try await withSQLiteDatabase { db, logger in
            let ds = self.items(db, logger)
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
        try await withSQLiteDatabase { db, logger in
            let ds = self.items(db, logger)
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
        try await withSQLiteDatabase { db, logger in
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
            #expect(try await self.items(db, logger).fetch(byId: "i1") != nil)
        }
    }

    @Test("a rolled-back transaction leaves neither the state change nor the outbox row")
    func outboxRollsBackWithTheStateChange() async throws {
        struct Boom: Error {}

        try await withSQLiteDatabase { db, logger in
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

            let relayStore = FluentOutboxStore(transaction: .direct(database: db), logger: logger)
            let pending = try await relayStore.pending(limit: 10, now: Date())
            let item = try await self.items(db, logger).fetch(byId: "i1")
            #expect(pending.isEmpty)
            #expect(item == nil)
        }
    }

    // MARK: - Request context across the transaction boundary

    /// Regression guard. FluentKit runs the async `transaction` closure in a
    /// `Task` started **on the event loop**, which inherits no task-locals — so
    /// without `RequestContext.restore`, everything a command depends on reads
    /// back as `nil` inside the unit of work: PEPs fail closed, and idempotency
    /// and inbox de-duplication silently turn themselves off. The failure mode is
    /// invisible (no error, just no de-duplication), which is why it is pinned.
    @Test("RequestContext survives into the unit of work's transaction")
    func requestContextCrossesTheTransactionBoundary() async throws {
        try await withSQLiteDatabase { db, logger in
            let unitOfWork = FluentUnitOfWork(
                database: db,
                dispatcher: SpyDomainEventDispatcher(),
                outbox: Outbox(),
                logger: logger
            )
            let eventId = UUID()
            let principal = StubPrincipal(id: "u1", roles: [.admin])

            let seen: (key: String?, event: UUID?, principal: String?) = try await RequestContext
                .$idempotencyKey.withValue(try IdempotencyKey("k1")) {
                    try await RequestContext.$integrationEventId.withValue(eventId) {
                        try await RequestContext.$principal.withValue(principal) {
                            try await unitOfWork.execute { _ in
                                (
                                    RequestContext.idempotencyKey?.rawValue,
                                    RequestContext.integrationEventId,
                                    RequestContext.principal?.id
                                )
                            }
                        }
                    }
                }

            #expect(seen.key == "k1")
            #expect(seen.event == eventId)
            #expect(seen.principal == "u1")
        }
    }

    // MARK: - Idempotency / Inbox uniqueness guards

    @Test("a second idempotency record for the same key violates the primary key")
    func idempotencyKeyIsUnique() async throws {
        try await withSQLiteDatabase { db, logger in
            let store = FluentIdempotencyStore(
                transaction: .direct(database: db),
                ttl: 3600,
                logger: logger
            )
            let fingerprint = try RequestFingerprint(payload: ["name": "Widget"])
            let ticket = IdempotencyTicket(id: "key-1", fingerprint: fingerprint, overwriteExpired: false)
            let response = StoredResponse(status: 201, body: Data("{}".utf8))

            try await store.complete(ticket: ticket, response: response)

            // The uniqueness constraint *is* the in-flight guard.
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

    @Test("a second inbox record for the same event violates the primary key")
    func inboxEventIdIsUnique() async throws {
        try await withSQLiteDatabase { db, logger in
            let store = FluentInboxStore(
                transaction: .direct(database: db),
                ttl: 7 * 24 * 3600,
                logger: logger
            )
            let ticket = InboxTicket(id: "inbox-1", overwriteExpired: false)

            try await store.complete(ticket: ticket)

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
