protocol DataSource<Model>: Sendable {
//    associatedtype Id: Sendable
    associatedtype Model: Sendable

    func fetch(byId id: String) async throws -> Model?

    func insert(model: Model) async throws

    func insert(models: [Model]) async throws

    func update(model: Model) async throws

    func update(models: [Model]) async throws

    func delete(byId id: String) async throws

    func delete(byIds ids: [String]) async throws

    // MARK: Optimistic concurrency (check-and-set)

    /// Update with check-and-set: persist `model` only if the stored
    /// optimistic-concurrency token equals `expected` (the token the aggregate
    /// was loaded with); throw `ConcurrencyError.versionConflict` otherwise.
    /// Returns the advanced token on success.
    ///
    /// Stores that have no versioning mechanism inherit the default below, which
    /// performs an unconditional update and reports `.none`.
    func update(model: Model, ifMatching expected: Version) async throws -> Version

    /// Delete with check-and-set: delete only if the stored token equals
    /// `expected`; throw `ConcurrencyError.versionConflict` otherwise.
    func delete(byId id: String, ifMatching expected: Version) async throws
}

// MARK: - Default (non-versioned) Implementations

extension DataSource {

    /// Default: ignore the token and update unconditionally. Versioned stores
    /// (e.g. Firestore over a `VersionedModel`) override this with real CAS.
    func update(model: Model, ifMatching expected: Version) async throws -> Version {
        try await update(model: model)
        return .none
    }

    /// Default: ignore the token and delete unconditionally.
    func delete(byId id: String, ifMatching expected: Version) async throws {
        try await delete(byId: id)
    }
}
