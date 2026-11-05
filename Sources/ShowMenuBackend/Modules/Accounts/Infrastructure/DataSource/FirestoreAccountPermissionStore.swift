import FirestoreAPI
import Logging

/// Firestore binding of ``AccountPermissionStore``; writes through the active
/// `FirestoreTransaction`, so the grant commits with the command's inbox marker.
struct FirestoreAccountPermissionStore: AccountPermissionStore {
    let transaction: FirestoreTransaction
    /// Collection prefix (`FIRESTORE_PATH_PREFIX` aware), "" for the root.
    let prefix: String
    let logger: Logger

    func put(_ permission: AccountPermissionModel, accountId: String, userId: String) async throws {
        let path = [prefix, "accounts", accountId, "permissions"].filter { !$0.isEmpty }.joined(separator: "/")
        logger.debug("Writing account permission", metadata: [
            "collection": .string(path), "documentId": .string(userId)
        ])
        do {
            let docRef = transaction.collection(path).document(userId)
            try await transaction.set(documentReference: docRef, from: permission)
        } catch {
            throw FirestoreError.from(grpcError: error)
        }
    }
}
