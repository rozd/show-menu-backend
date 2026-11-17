import Foundation
import Testing
@testable import ShowMenuBackend

/// Exercises optimistic-concurrency check-and-set through the real
/// `DefaultUserRepository` backed by a capturing `VersionedModel` store, so the
/// test covers the repository's token lifecycle and the CAS contract at the
/// DataSource seam.
@Suite("Optimistic Concurrency (check-and-set)")
struct OptimisticConcurrencyTests {

    private let mapper = UserMapper()

    private func makeRepo(ds: SpyVersionedDataSource<UserModel>) -> any UserRepository {
        let ctx = StubUnitOfWorkContext(
            transaction: "stub",
            collector: InProcessDomainEventCollector()
        )
        return DefaultUserRepository(
            mapper: mapper,
            dataSourceFactory: { _, _ in ds },
            context: ctx
        )
    }

    private func model(_ id: String, name: String, version: Int?) -> UserModel {
        UserModel(id: id, displayName: name, version: version)
    }

    /// `User` exposes no behaviour methods, so a "change" is a new instance
    /// carrying the loaded aggregate's id and version token — exactly what a
    /// mutating behaviour would leave behind for the repository to persist.
    private func edited(_ user: User, name: String) -> User {
        User(id: user.id, displayName: name, version: user.version)
    }

    // MARK: - Insert establishes a token

    @Test("insert establishes an initial version token")
    func insertEstablishesToken() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        let repo = makeRepo(ds: ds)

        let item = User(id: User.Id(rawValue: "new"), displayName: "New")
        try await repo.insert(entity: item)

        #expect(item.version == Version(1))
        let stored = await ds.current(item.id.rawValue)
        #expect(stored?.version == 1)
    }

    // MARK: - Fresh write advances

    @Test("fresh update succeeds and advances the token")
    func freshUpdateAdvances() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        let loaded = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))
        #expect(loaded.version == Version(5))

        let item = edited(loaded, name: "Updated")
        try await repo.update(entity: item)

        #expect(item.version == Version(6))                 // in-process token advanced
        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.displayName == "Updated")
    }

    // MARK: - Stale write conflicts and does not persist

    @Test("stale update raises ConcurrencyError and does not persist")
    func staleUpdateConflicts() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        // Load at v5, then another writer advances the stored doc to v6.
        let loaded = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))
        await ds.seed(model("i1", name: "Other", version: 6))

        let item = edited(loaded, name: "Mine")
        await #expect(throws: ConcurrencyError.self) {
            try await repo.update(entity: item)
        }

        // Nothing persisted: the other writer's value is intact.
        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.displayName == "Other")
        #expect(await ds.updatedModels.isEmpty)
    }

    // MARK: - Two concurrent writers

    @Test("two concurrent writers: one succeeds, the other conflicts")
    func concurrentWriters() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        // Both load the same version (v5).
        let loadedA = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))
        let loadedB = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))

        let writerA = edited(loadedA, name: "A")
        try await repo.update(entity: writerA)              // wins → v6
        #expect(writerA.version == Version(6))

        let writerB = edited(loadedB, name: "B")
        await #expect(throws: ConcurrencyError.self) {      // still expects v5 → conflict
            try await repo.update(entity: writerB)
        }

        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.displayName == "A")
    }

    // MARK: - Delete is also guarded

    @Test("stale delete raises ConcurrencyError and does not delete")
    func staleDeleteConflicts() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        await ds.seed(model("i1", name: "X", version: 5))
        let repo = makeRepo(ds: ds)

        let item = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))
        await ds.seed(model("i1", name: "X", version: 7))   // advanced by someone else

        await #expect(throws: ConcurrencyError.self) {
            try await repo.delete(entity: item)
        }
        #expect(await ds.current("i1") != nil)
        #expect(await ds.deletedIds.isEmpty)
    }

    // MARK: - Migration: a legacy document (no version field) adopts versioning

    @Test("legacy document with no version adopts versioning on first write")
    func legacyDocumentAdoptsVersioning() async throws {
        let ds = SpyVersionedDataSource<UserModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Legacy", version: nil)) // pre-versioning doc
        let repo = makeRepo(ds: ds)

        let loaded = try #require(try await repo.fetch(byId: User.Id(rawValue: "i1")))
        #expect(loaded.version == .none)                    // absent field -> .none

        let item = edited(loaded, name: "Migrated")
        try await repo.update(entity: item)                 // .none matches absent -> v1

        #expect(item.version == Version(1))
        #expect(await ds.current("i1")?.version == 1)
    }
}
