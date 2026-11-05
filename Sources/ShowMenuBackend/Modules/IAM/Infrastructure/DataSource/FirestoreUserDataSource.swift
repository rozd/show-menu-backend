import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

struct FirestoreUserDataSource: FirestoreDataSource, UserDataSource {
    typealias Model = UserModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "users"
    let logger: Logger

    func documentId(for model: UserModel) -> String {
        model.id
    }
}
