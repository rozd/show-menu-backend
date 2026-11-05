import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

struct FirestorePlanSKUDataSource: FirestoreDataSource, PlanSKUDataSource {
    typealias Model = PlanSKUModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "plan_skus"
    let logger: Logger

    func documentId(for model: PlanSKUModel) -> String {
        model.id
    }
}
