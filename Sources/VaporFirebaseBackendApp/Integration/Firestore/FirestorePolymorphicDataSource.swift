import Logging

struct FirestorePolymorphicDataSource: PolymorphicDataSource {
    let transaction: FirestoreTransaction
    let prefix: String
    let suffix: String
    let logger: Logger

    var collectionPath: String {
        [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
    }

    func fetch<T>(_ key: PolymorphicDataKey<T>) async throws -> T? {
        let docRef = transaction.collection(collectionPath).document(key.key)
        return try await transaction.getDocument(T.self, documentReference: docRef)
    }

    func insert<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws {
        let docRef = transaction.collection(collectionPath).document(key.key)
        try await transaction.create(documentReference: docRef, from: value)
    }

    func update<T>(_ value: T, for key: PolymorphicDataKey<T>) async throws {
        let docRef = transaction.collection(collectionPath).document(key.key)
        try await transaction.update(documentReference: docRef, from: value)
    }

    func delete<T>(_ key: PolymorphicDataKey<T>) async throws {
        let docRef = transaction.collection(collectionPath).document(key.key)
        try await transaction.delete(documentReference: docRef)
    }
}
