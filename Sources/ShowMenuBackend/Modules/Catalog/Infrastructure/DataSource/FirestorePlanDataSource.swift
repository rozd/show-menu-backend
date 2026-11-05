import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

struct FirestorePlanDataSource: FirestoreDataSource, PlanDataSource {
    typealias Model = PlanModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "plans"
    let logger: Logger

    func documentId(for model: PlanModel) -> String {
        model.id
    }
}
