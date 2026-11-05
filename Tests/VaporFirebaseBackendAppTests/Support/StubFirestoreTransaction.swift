import FirestoreAPI
@testable import VaporFirebaseBackendApp

private struct StubTransactionProtocol: FirestoreTransactionProtocol {
    func get(documentReference: DocumentReference) async throws -> DocumentSnapshot {
        fatalError("StubTransactionProtocol.get(documentReference:) not implemented")
    }
    func get(query: FirestoreAPI.Query) async throws -> QuerySnapshot {
        fatalError("StubTransactionProtocol.get(query:) not implemented")
    }
    func create(documentReference: DocumentReference, data: [String: Any]) {}
    func set(documentReference: DocumentReference, data: [String: Any]) {}
    func set(documentReference: DocumentReference, data: [String: Any], merge: Bool) {}
    func update(documentReference: DocumentReference, data: [String: Any]) {}
    func delete(documentReference: DocumentReference) {}
}

private struct StubReferenceProvider: FirestoreReferenceProvider {
    func collection(_ collectionID: String) -> CollectionReference {
        fatalError("StubReferenceProvider.collection(_:) not implemented")
    }
    func document(_ documentID: String) -> DocumentReference {
        fatalError("StubReferenceProvider.document(_:) not implemented")
    }
    func collectionGroup(_ groupID: String) -> CollectionGroup {
        fatalError("StubReferenceProvider.collectionGroup(_:) not implemented")
    }
    func count(_ collection: CollectionReference) async throws -> Int {
        fatalError("StubReferenceProvider.count(_:) not implemented")
    }
}

extension FirestoreTransaction {
    static var stub: FirestoreTransaction {
        FirestoreTransaction(
            wrapping: StubTransactionProtocol(),
            referenceProvider: StubReferenceProvider()
        )
    }
}
