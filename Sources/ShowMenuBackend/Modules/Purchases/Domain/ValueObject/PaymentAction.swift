import Foundation

/// Node's `PaymentAction`: how the provider charges the invoice.
enum PaymentAction: String, Sendable, Hashable, Codable {
    case pay
    case subscribe
}

/// Node's `ShippingMethod` (only `electronic` exists).
enum ShippingMethod: String, Sendable, Hashable, Codable {
    case electronic
}
