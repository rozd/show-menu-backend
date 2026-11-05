protocol PolymorphicDataSource: Sendable {
    func fetch<T>(_ key: PolymorphicDataKey<T>) async throws -> T?
    func insert<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws
    func update<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws
    func delete<T>(_ key: PolymorphicDataKey<T>) async throws
}

struct PolymorphicDataKey<Value: Sendable & Codable>: Sendable {
    let key: String
}
