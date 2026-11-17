@testable import ShowMenuBackend

/// A generic capturing test double conforming to `QueryableDataSource<Model>`.
///
/// It keeps its own dictionary rather than talking to a database, so a unit test
/// can assert on the *interactions*
/// (`insertedModels` / `updatedModels` / `deletedIds` / `queries`) instead of
/// only on the resulting state.
///
/// Usage:
/// ```swift
/// let ds = SpyDataSource<UserModel>(id: { $0.id })
/// await ds.seed(UserModel(id: "u1", displayName: "Widget"))
/// let result = try await ds.fetch(byId: "i1")
/// ```
actor SpyDataSource<Model: Sendable>: QueryableDataSource {

    private var store: [String: Model] = [:]
    private let extractId: @Sendable (Model) -> String

    // MARK: - Captured interactions

    private(set) var insertedModels: [Model] = []
    private(set) var updatedModels: [Model] = []
    private(set) var deletedIds: [String] = []
    private(set) var queries: [DataSourceQuery] = []

    init(id: @escaping @Sendable (Model) -> String) {
        self.extractId = id
    }

    // MARK: - DataSource

    func fetch(byId id: String) async throws -> Model? {
        store[id]
    }

    func insert(model: Model) async throws {
        let id = extractId(model)
        store[id] = model
        insertedModels.append(model)
    }

    func insert(models: [Model]) async throws {
        for model in models {
            let id = extractId(model)
            store[id] = model
            insertedModels.append(model)
        }
    }

    func update(model: Model) async throws {
        let id = extractId(model)
        store[id] = model
        updatedModels.append(model)
    }

    func update(models: [Model]) async throws {
        for model in models {
            let id = extractId(model)
            store[id] = model
            updatedModels.append(model)
        }
    }

    func delete(byId id: String) async throws {
        store.removeValue(forKey: id)
        deletedIds.append(id)
    }

    func delete(byIds ids: [String]) async throws {
        for id in ids {
            store.removeValue(forKey: id)
            deletedIds.append(id)
        }
    }

    // MARK: - QueryableDataSource

    func query(_ query: DataSourceQuery) async throws -> QueryResult<Model> {
        queries.append(query)
        return QueryResult(items: Array(store.values))
    }

    // MARK: - Test helpers

    /// Pre-populate a single model without tracking it as an insert.
    func seed(_ model: Model) {
        store[extractId(model)] = model
    }

    /// Pre-populate multiple models without tracking them as inserts.
    func seed(_ models: [Model]) {
        for model in models {
            store[extractId(model)] = model
        }
    }

    /// Clear all stored data and captured interactions.
    func reset() {
        store.removeAll()
        insertedModels.removeAll()
        updatedModels.removeAll()
        deletedIds.removeAll()
        queries.removeAll()
    }
}
