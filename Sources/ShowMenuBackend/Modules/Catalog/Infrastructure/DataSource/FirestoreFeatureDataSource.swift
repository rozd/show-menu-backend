import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

struct FirestoreFeatureDataSource: FirestoreDataSource, FeatureDataSource {
    typealias Model = FeatureModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "features"
    let logger: Logger

    func documentId(for model: FeatureModel) -> String {
        model.id
    }
}
