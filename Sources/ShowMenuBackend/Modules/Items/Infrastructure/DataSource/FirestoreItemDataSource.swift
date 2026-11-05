import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

struct FirestoreItemDataSource: FirestoreDataSource, ItemDataSource {
    typealias Model = ItemModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "items"
    let logger: Logger

    func documentId(for model: ItemModel) -> String {
        model.id
    }
}
