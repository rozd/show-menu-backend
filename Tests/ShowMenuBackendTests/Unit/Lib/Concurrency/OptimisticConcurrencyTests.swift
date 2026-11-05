import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

/// Exercises optimistic-concurrency check-and-set through the real
/// `FirestoreFeatureRepository` backed by an in-memory `VersionedModel` store,
/// so the test covers the repository's token lifecycle and the CAS contract
/// without Firestore.
@Suite("Optimistic Concurrency (check-and-set)")
struct OptimisticConcurrencyTests {

    private let mapper = FeatureMapper()

    private func makeRepo(ds: InMemoryVersionedDataSource<FeatureModel>) -> any FeatureRepository {
        let ctx = StubUnitOfWorkContext(
            transaction: "stub",
            collector: InMemoryDomainEventCollector()
        )
        return FirestoreFeatureRepository(
            mapper: mapper,
            dataSourceFactory: { _, _ in ds },
            context: ctx
        )
    }

    private func ls(_ text: String) -> LocalizedString {
        try! LocalizedString(["en": text])
    }

    private func model(_ id: String, name: String, version: Int?) -> FeatureModel {
        FeatureModel(
            id: id,
            category: .ai,
            name: ls(name),
            description: nil,
            version: version,
            createdAt: Timestamp(seconds: 0, nanos: 0),
            updatedAt: Timestamp(seconds: 0, nanos: 0)
        )
    }

    // MARK: - Insert establishes a token

    @Test("insert establishes an initial version token")
    func insertEstablishesToken() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        let repo = makeRepo(ds: ds)

        let feature = try Feature.create(category: .ai, name: ls("New"), description: nil)
        try await repo.insert(entity: feature)

        #expect(feature.version == Version(1))
        let stored = await ds.current(feature.id.rawValue)
        #expect(stored?.version == 1)
    }

    // MARK: - Fresh write advances

    @Test("fresh update succeeds and advances the token")
    func freshUpdateAdvances() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        let feature = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))
        #expect(feature.version == Version(5))

        try feature.update(name: ls("Updated"))
        try await repo.update(entity: feature)

        #expect(feature.version == Version(6))                 // in-process token advanced
        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.name.values["en"] == "Updated")
    }

    // MARK: - Stale write conflicts and does not persist

    @Test("stale update raises ConcurrencyError and does not persist")
    func staleUpdateConflicts() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        // Load at v5, then another writer advances the stored doc to v6.
        let feature = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))
        await ds.seed(model("i1", name: "Other", version: 6))

        try feature.update(name: ls("Mine"))
        await #expect(throws: ConcurrencyError.self) {
            try await repo.update(entity: feature)
        }

        // Nothing persisted: the other writer's value is intact.
        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.name.values["en"] == "Other")
        #expect(await ds.updatedModels.isEmpty)
    }

    // MARK: - Two concurrent writers

    @Test("two concurrent writers: one succeeds, the other conflicts")
    func concurrentWriters() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Original", version: 5))
        let repo = makeRepo(ds: ds)

        // Both load the same version (v5).
        let writerA = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))
        let writerB = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))

        try writerA.update(name: ls("A"))
        try await repo.update(entity: writerA)              // wins → v6
        #expect(writerA.version == Version(6))

        try writerB.update(name: ls("B"))
        await #expect(throws: ConcurrencyError.self) {      // still expects v5 → conflict
            try await repo.update(entity: writerB)
        }

        let stored = await ds.current("i1")
        #expect(stored?.version == 6)
        #expect(stored?.name.values["en"] == "A")
    }

    // MARK: - Delete is also guarded

    @Test("stale delete raises ConcurrencyError and does not delete")
    func staleDeleteConflicts() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        await ds.seed(model("i1", name: "X", version: 5))
        let repo = makeRepo(ds: ds)

        let feature = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))
        await ds.seed(model("i1", name: "X", version: 7))   // advanced by someone else

        await #expect(throws: ConcurrencyError.self) {
            try await repo.delete(entity: feature)
        }
        #expect(await ds.current("i1") != nil)
        #expect(await ds.deletedIds.isEmpty)
    }

    // MARK: - Migration: a legacy document (no version field) adopts versioning

    @Test("legacy document with no version adopts versioning on first write")
    func legacyDocumentAdoptsVersioning() async throws {
        let ds = InMemoryVersionedDataSource<FeatureModel>(id: { $0.id })
        await ds.seed(model("i1", name: "Legacy", version: nil)) // pre-versioning doc
        let repo = makeRepo(ds: ds)

        let feature = try #require(try await repo.fetch(byId: Feature.Id(rawValue: "i1")))
        #expect(feature.version == .none)                      // absent field -> .none

        try feature.update(name: ls("Migrated"))
        try await repo.update(entity: feature)                 // .none matches absent -> v1

        #expect(feature.version == Version(1))
        #expect(await ds.current("i1")?.version == 1)
    }
}
