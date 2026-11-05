import FirestoreAPI
import GRPCCore
import Logging

// MARK: - Firestore Check-and-Set

extension FirestoreDataSource where Model: VersionedModel {

    /// Check-and-set update inside the active transaction.
    ///
    /// `updateTime` would be the natural store-native token, but the pinned
    /// FirebaseAPI client neither surfaces it on reads nor accepts it as a write
    /// precondition (only `exists`). So the token is bound to an explicit integer
    /// `version` field and enforced here: read the current document, compare its
    /// stored `version` to `expected`, then either advance (`version + 1`) or
    /// throw `ConcurrencyError`. The read precedes the write — satisfying
    /// Firestore's read-before-write rule — and the surrounding transaction is a
    /// serializable backstop at commit.
    func update(model: Model, ifMatching expected: Version) async throws -> Version {
        let id = documentId(for: model)
        let docRef = transaction.collection(collectionPath).document(id)
        logger.debug("Checked update", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id),
            "expectedVersion": .string(expected.description)
        ])
        do {
            let current = try await transaction.getDocument(Model.self, documentReference: docRef)
            let actual = Version(versionInt: current?.version)
            guard expected == actual else {
                throw ConcurrencyError.versionConflict(
                    entity: suffix, id: id, expected: expected, actual: actual
                )
            }
            var next = model
            let nextInt = (current?.version ?? 0) + 1
            next.version = nextInt
            try await transaction.update(documentReference: docRef, from: next)
            return Version(nextInt)
        } catch let error as ConcurrencyError {
            // Surface the conflict unchanged — never collapse it into a generic
            // Firestore error.
            throw error
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore checked update failed", metadata: [
                "collection": .string(collectionPath), "documentId": .string(id),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }

    /// Check-and-set delete inside the active transaction. A document that is
    /// already gone is treated as an idempotent success.
    func delete(byId id: String, ifMatching expected: Version) async throws {
        let docRef = transaction.collection(collectionPath).document(id)
        logger.debug("Checked delete", metadata: [
            "collection": .string(collectionPath), "documentId": .string(id),
            "expectedVersion": .string(expected.description)
        ])
        do {
            guard let current = try await transaction.getDocument(Model.self, documentReference: docRef) else {
                return
            }
            let actual = Version(versionInt: current.version)
            guard expected == actual else {
                throw ConcurrencyError.versionConflict(
                    entity: suffix, id: id, expected: expected, actual: actual
                )
            }
            try await transaction.delete(documentReference: docRef)
        } catch let error as ConcurrencyError {
            throw error
        } catch {
            let mapped = FirestoreError.from(grpcError: error)
            logger.error("Firestore checked delete failed", metadata: [
                "collection": .string(collectionPath), "documentId": .string(id),
                "mappedError": .string(String(describing: mapped)),
                "mappedDescription": .string(mapped.errorDescription ?? "")
            ])
            throw mapped
        }
    }
}
