import Foundation

/// `accounts/{accountId}/checkout-sessions/{invoiceId}` — what Flutter reads
/// (`status`, `paymentPageURL`, `transactionId`, `errorCode/Message/Details`).
///
/// The extension wrote exactly `{status, invoiceId, paymentPageURL, transactionId, errorCode,
/// errorMessage, errorDetails}` with explicit `null`s and **no timestamps** (Admin SDK
/// create/update times live in document metadata). Vapor adds `orderId` (additive; Flutter
/// ignores it) and writes no timestamps either. No `version`: sessions are not aggregates.
struct CheckoutSessionModel: Codable, Sendable, Equatable {
    let status: CheckoutSessionStatus
    let invoiceId: String
    let orderId: String?
    let paymentPageURL: String?
    let transactionId: String?
    let errorCode: String?
    let errorMessage: String?
    let errorDetails: String?

    init(
        status: CheckoutSessionStatus, invoiceId: String, orderId: String? = nil, paymentPageURL: String? = nil,
        transactionId: String? = nil, errorCode: String? = nil, errorMessage: String? = nil, errorDetails: String? = nil
    ) {
        self.status = status
        self.invoiceId = invoiceId
        self.orderId = orderId
        self.paymentPageURL = paymentPageURL
        self.transactionId = transactionId
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorDetails = errorDetails
    }

    private enum CodingKeys: String, CodingKey {
        case status, invoiceId, orderId, paymentPageURL, transactionId, errorCode, errorMessage, errorDetails
    }

    /// Legacy-tolerant: everything but `status` and `invoiceId` may be absent (no `orderId` in extension docs).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decode(CheckoutSessionStatus.self, forKey: .status)
        self.invoiceId = try c.decode(String.self, forKey: .invoiceId)
        self.orderId = try c.decodeIfPresent(String.self, forKey: .orderId)
        self.paymentPageURL = try c.decodeIfPresent(String.self, forKey: .paymentPageURL)
        self.transactionId = try c.decodeIfPresent(String.self, forKey: .transactionId)
        self.errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.errorDetails = try c.decodeIfPresent(String.self, forKey: .errorDetails)
    }

    /// Absent optionals are written as explicit `null`, like the extension.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(invoiceId, forKey: .invoiceId)
        try c.encode(orderId, forKey: .orderId)
        try c.encode(paymentPageURL, forKey: .paymentPageURL)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(errorCode, forKey: .errorCode)
        try c.encode(errorMessage, forKey: .errorMessage)
        try c.encode(errorDetails, forKey: .errorDetails)
    }
}
