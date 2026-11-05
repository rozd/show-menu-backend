@testable import ShowMenuBackend

/// In-memory `DataSource` test double that implements optimistic-concurrency
/// check-and-set for `VersionedModel`s, mirroring the Firestore binding's CAS
/// semantics without Firestore. Used by the optimistic-concurrency unit tests.
///
/// Unlike `InMemoryDataSource` (which inherits the unconditional no-op CAS
/// defaults), this double provides `update(model:ifMatching:)` /
/// `delete(byId:ifMatching:)` in its body, so those are the dispatched witnesses
/// even through an `any DataSource<Model>` existential.
actor InMemoryVersionedDataSource<Model: VersionedModel>: QueryableDataSource {

    private var store: [String: Model] = [:]
    private let extractId: @Sendable (Model) -> String

    private(set) var insertedModels: [Model] = []
    private(set) var updatedModels: [Model] = []
    private(set) var deletedIds: [String] = []

    init(id: @escaping @Sendable (Model) -> String) {
        self.extractId = id
    }

    // MARK: - DataSource (unconditional)

    func fetch(byId id: String) async throws -> Model? {
        store[id]
    }

    func insert(model: Model) async throws {
        store[extractId(model)] = model
        insertedModels.append(model)
    }

    func insert(models: [Model]) async throws {
        for model in models { try await insert(model: model) }
    }

    func update(model: Model) async throws {
        store[extractId(model)] = model
        updatedModels.append(model)
    }

    func update(models: [Model]) async throws {
        for model in models { try await update(model: model) }
    }

    func delete(byId id: String) async throws {
        store.removeValue(forKey: id)
        deletedIds.append(id)
    }

    func delete(byIds ids: [String]) async throws {
        for id in ids { try await delete(byId: id) }
    }

    // MARK: - DataSource (check-and-set)

    func update(model: Model, ifMatching expected: Version) async throws -> Version {
        let id = extractId(model)
        let actual = Version(versionInt: store[id]?.version)
        guard expected == actual else {
            throw ConcurrencyError.versionConflict(
                entity: "model", id: id, expected: expected, actual: actual
            )
        }
        var next = model
        let nextInt = (store[id]?.version ?? 0) + 1
        next.version = nextInt
        store[id] = next
        updatedModels.append(next)
        return Version(nextInt)
    }

    func delete(byId id: String, ifMatching expected: Version) async throws {
        guard let current = store[id] else { return }
        let actual = Version(versionInt: current.version)
        guard expected == actual else {
            throw ConcurrencyError.versionConflict(
                entity: "model", id: id, expected: expected, actual: actual
            )
        }
        store.removeValue(forKey: id)
        deletedIds.append(id)
    }

    // MARK: - QueryableDataSource

    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model> {
        QueryResult(items: Array(store.values))
    }

    func countAll() async throws -> Int {
        store.count
    }

    // MARK: - Test helpers

    func seed(_ model: Model) {
        store[extractId(model)] = model
    }

    /// The currently stored model (for asserting persistence/advancement).
    func current(_ id: String) -> Model? {
        store[id]
    }
}
