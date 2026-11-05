@testable import ShowMenuBackend

/// A generic in-memory test double conforming to `QueryableDataSource<Model>`.
///
/// Usage:
/// ```swift
/// let ds = InMemoryDataSource<FeatureModel>(id: { $0.id })
/// await ds.seed(FeatureModel(id: "feature-1", category: .ai, name: name, description: nil, version: nil, createdAt: ts, updatedAt: ts))
/// let result = try await ds.fetch(byId: "feature-1")
/// ```
actor InMemoryDataSource<Model: Sendable>: QueryableDataSource {

    private var store: [String: Model] = [:]
    private let extractId: @Sendable (Model) -> String
    /// Optional filter evaluator. Without it `query` ignores filters (legacy
    /// behaviour); with it every filter must hold for a model to be returned.
    private let matchesFilter: (@Sendable (Model, DataSourceFilter) -> Bool)?

    // MARK: - Captured interactions

    private(set) var insertedModels: [Model] = []
    private(set) var updatedModels: [Model] = []
    private(set) var deletedIds: [String] = []
    private(set) var queries: [DataSourceQuery] = []

    init(
        id: @escaping @Sendable (Model) -> String,
        matchesFilter: (@Sendable (Model, DataSourceFilter) -> Bool)? = nil
    ) {
        self.extractId = id
        self.matchesFilter = matchesFilter
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
        // In-memory ignores `orders`/`filters`; items are sorted by extracted id
        // so `offset`/`limit` paging is deterministic.
        var items = store.values.sorted { extractId($0) < extractId($1) }
        if let matchesFilter {
            items = items.filter { model in query.filters.allSatisfy { matchesFilter(model, $0) } }
        }
        if let offset = query.offset { items = Array(items.dropFirst(offset)) }
        if let limit = query.limit { items = Array(items.prefix(limit)) }
        return QueryResult(items: items)
    }

    func countAll() async throws -> Int {
        store.count
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
