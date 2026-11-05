import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

/// `accounts/{accountId}/subscriptions` — the account comes in through `prefix`
/// (`accounts/{accountId}`), see ``FirestoreSubscriptionRepository``.
struct FirestoreSubscriptionDataSource: FirestoreDataSource, SubscriptionDataSource {
    typealias Model = SubscriptionModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "subscriptions"
    let logger: Logger

    func documentId(for model: SubscriptionModel) -> String {
        model.id
    }
}
