import Foundation

/// Minimal read projections required by the `Mapper` contract. No S10-S13 endpoint
/// returns an order or invoice body (purchase answers a `text/plain` invoice id, cancel is empty).
struct OrderDTO: Codable, Sendable, Equatable {
    let id: String
    let accountId: String
    let customerId: String
    let status: String
    let invoiceId: String?
    let createdAt: String
    let updatedAt: String
}

struct InvoiceDTO: Codable, Sendable, Equatable {
    let id: String
    let orderId: String
    let accountId: String
    let customerId: String
    let status: String
    let transactionId: String?
    let createdAt: String
    let updatedAt: String
}
