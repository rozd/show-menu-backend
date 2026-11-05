import Foundation

/// A status change the state machine does not allow. A domain-rule violation (409), not
/// a validation failure: the request was well-formed but the aggregate is in the wrong state.
struct InvalidStatusTransitionError: DomainError, LocalizedError, Equatable {
    let aggregate: String
    let id: String
    let from: String
    let to: String

    var errorDescription: String? { "Invalid \(aggregate) status transition from \(from) to \(to)" }
}

/// The invoice named in a status change is not the order's invoice.
struct InvoiceOrderMismatchError: DomainError, LocalizedError, Equatable {
    let orderId: Order.Id
    let invoiceId: Invoice.Id

    var errorDescription: String? { "Invoice \(invoiceId.rawValue) does not belong to order \(orderId.rawValue)" }
}

/// The order already has an invoice.
struct OrderInvoiceAlreadyCreatedError: DomainError, LocalizedError, Equatable {
    let orderId: Order.Id

    var errorDescription: String? { "Order \(orderId.rawValue) already has an invoice" }
}
