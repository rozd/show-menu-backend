import Foundation
@testable import ShowMenuBackend

final class InMemoryPolymorphicDataSource: PolymorphicDataSource, @unchecked Sendable {

    private let lock = NSLock()
    private var store: [String: Any] = [:]
    private(set) var deletedKeys: [String] = []

    // MARK: - PolymorphicDataSource

    func fetch<T>(_ key: PolymorphicDataKey<T>) async throws -> T? {
        lock.withLock { store[key.key] as? T }
    }

    func insert<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws {
        lock.withLock { store[key.key] = value }
    }

    func update<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws {
        lock.withLock { store[key.key] = value }
    }

    func delete<T>(_ key: PolymorphicDataKey<T>) async throws {
        lock.withLock {
            store.removeValue(forKey: key.key)
            deletedKeys.append(key.key)
        }
    }

    // MARK: - Test helpers

    func seed<T>(key: PolymorphicDataKey<T>, value: T) {
        lock.withLock { store[key.key] = value }
    }

    func reset() {
        lock.withLock {
            store.removeAll()
            deletedKeys.removeAll()
        }
    }
}
