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

/// The plan exists but is not on sale (`isActive == false`). 422.
struct PlanNotActiveError: ValidationError, LocalizedError, Equatable {
    let planId: String
    var errorDescription: String? { "Plan \(planId) is not active" }
}

/// The requested price is not one of the plan's prices (D9: duration + currency name +
/// amount must match). 422 (Node threw a plain `Error`, which surfaced as 500).
struct PlanPriceMismatchError: ValidationError, LocalizedError, Equatable {
    let planId: String
    var errorDescription: String? { "Invalid price for plan \(planId)" }
}

/// The account already has a pending checkout session. 409 (`Purchases+Vapor.swift`).
struct PendingCheckoutSessionError: DomainError, LocalizedError, Equatable {
    let accountId: String
    var errorDescription: String? { "There is already a pending order" }
}

/// There is neither a `users/{uid}` document nor a token email to bill. 404 (`Purchases+Vapor.swift`).
struct CustomerNotFoundError: DomainError, LocalizedError, Equatable {
    let userId: String
    var errorDescription: String? { "Customer not found" }
}
