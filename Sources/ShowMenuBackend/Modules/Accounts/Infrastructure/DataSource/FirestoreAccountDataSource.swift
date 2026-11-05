import FirestoreAPI
import Logging

struct FirestoreAccountDataSource: FirestoreDataSource, AccountDataSource {
    typealias Model = AccountModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "accounts"
    let logger: Logger

    func documentId(for model: AccountModel) -> String {
        model.id
    }
}
