import Foundation

/// Status of `accounts/{a}/checkout-sessions/{invoiceId}` as **Flutter** parses it
/// (`CheckoutSessionStatus.values.firstWhere((e) => e.name == data['status'])`): any
/// other string makes the client throw. The extension wrote the same four. (The
/// harness contract's `pending|completed|expired|cancelled` is wrong.)
enum CheckoutSessionStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending, cancelled, success, failure
}

struct CheckoutSessionError: Sendable, Hashable {
    let code: String
    let message: String?
    let details: String?
}

/// Client-visible checkout state. A plain value (the document id is the invoice id,
/// the account comes from the path), not an aggregate.
struct CheckoutSession: Sendable, Hashable {
    let invoiceId: Invoice.Id
    let accountId: String
    /// Additive: the extension did not write it; Flutter ignores it.
    let orderId: Order.Id?
    let status: CheckoutSessionStatus
    let paymentPageURL: String?
    let transactionId: String?
    let error: CheckoutSessionError?
}
