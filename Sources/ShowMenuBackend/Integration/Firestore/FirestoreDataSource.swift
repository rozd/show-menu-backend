import FirestoreAPI
import GRPCCore
import Logging

/// Data source protocol for Firestore using FirebaseAPI gRPC client
protocol FirestoreDataSource<Model>: DataSource where Model: Codable & Sendable {

    /// The FirebaseAPI Firestore client instance
    var transaction: FirestoreTransaction { get }

    /// Collection path prefix (e.g., for multi-tenancy)
    var prefix: String { get }

    /// Collection name suffix (the actual collection name)
    var suffix: String { get }

    /// Logger for data-access operations
    var logger: Logger { get }

    /// Extracts document ID from the model
    /// - Parameter model: The model instance
    /// - Returns: Document ID string
    func documentId(for model: Model) -> String
}

// MARK: - Default Implementation

extension FirestoreDataSource {

    var collectionPath: String {
        [prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/")
    }

    func fetch(byId id: String) async throws -> Model? {
        logger.debug("Fetching document", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id)
        ])
        do {
            let docRef = transaction.collection(collectionPath).document(id)
            return try await transaction.getDocument(Model.self, documentReference: docRef)
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore fetch failed", metadata: [
                "collection": .string(collectionPath), "documentId": .string(id),
                "errorType": .string(String(reflecting: type(of: error))),
                "errorDetail": .string(String(reflecting: error)),
                "errorDescription": .string(error.localizedDescription),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    func insert(model: Model) async throws {
        let id = documentId(for: model)
        logger.debug("Inserting document", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id)
        ])
        do {
            let docRef = transaction.collection(collectionPath).document(id)
            try await transaction.create(documentReference: docRef, from: model)
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore insert failed", metadata: [
                "collection": .string(collectionPath), "documentId": .string(id),
                "errorType": .string(String(reflecting: type(of: error))),
                "errorDetail": .string(String(reflecting: error)),
                "errorDescription": .string(error.localizedDescription),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    func insert(models: [Model]) async throws {
        logger.debug("Inserting documents", metadata: [
            "collection": .string(collectionPath), "count": .string(String(models.count))
        ])
        for model in models {
            try await insert(model: model)
        }
    }

    func update(model: Model) async throws {
        let id = documentId(for: model)
        logger.debug("Updating document", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id)
        ])
        do {
            let docRef = transaction.collection(collectionPath).document(id)
            try await transaction.update(documentReference: docRef, from: model)
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore update failed", metadata: [
                "collection": .string(collectionPath), "documentId": .string(id),
                "errorType": .string(String(reflecting: type(of: error))),
                "errorDetail": .string(String(reflecting: error)),
                "errorDescription": .string(error.localizedDescription),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    func update(models: [Model]) async throws {
        logger.debug("Updating documents", metadata: [
            "collection": .string(collectionPath), "count": .string(String(models.count))
        ])
        for model in models {
            try await update(model: model)
        }
    }

    func delete(byId id: String) async throws {
        logger.debug("Deleting document", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id)
        ])
        let docRef = transaction.collection(collectionPath).document(id)
        try await transaction.delete(documentReference: docRef)
    }

    /// Delete multiple documents by IDs
    func delete(byIds ids: [String]) async throws {
        logger.debug("Deleting documents", metadata: [
            "collection": .string(collectionPath), "count": .string(String(ids.count))
        ])
        for id in ids {
            try await delete(byId: id)
        }
    }
}
