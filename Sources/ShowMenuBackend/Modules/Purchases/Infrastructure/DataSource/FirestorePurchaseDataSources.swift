import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

/// `accounts/{accountId}/orders` — the account comes in through `prefix`
/// (`accounts/{accountId}`), see ``FirestoreOrderRepository``.
struct FirestoreOrderDataSource: FirestoreDataSource, OrderDataSource {
    typealias Model = OrderModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "orders"
    let logger: Logger

    func documentId(for model: OrderModel) -> String {
        model.id
    }
}

/// `invoices`.
struct FirestoreInvoiceDataSource: FirestoreDataSource, InvoiceDataSource {
    typealias Model = InvoiceModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "invoices"
    let logger: Logger

    func documentId(for model: InvoiceModel) -> String {
        model.id
    }
}

/// `accounts/{accountId}/checkout-sessions` — the document id is the invoice id.
struct FirestoreCheckoutSessionDataSource: FirestoreDataSource, CheckoutSessionDataSource {
    typealias Model = CheckoutSessionModel

    let transaction: FirestoreTransaction
    let prefix: String
    let suffix = "checkout-sessions"
    let logger: Logger

    func documentId(for model: CheckoutSessionModel) -> String {
        model.invoiceId
    }
}
