import Foundation

/// Port to the external payment provider. Implemented by the LiqPay adapter in
/// `Integration/LiqPay`; faked in tests and in the emulator.
protocol PaymentGateway: Sendable {

    /// True when the provider is configured with test credentials: successful
    /// payments move no real money.
    var isSandbox: Bool { get }

    /// Signs the checkout envelope, POSTs it to the provider's checkout endpoint
    /// and returns the hosted payment page URL (the redirect `Location`).
    /// Throws `notConfigured` when no callback (`server_url`) is configured:
    /// the provider could never report the result.
    func checkout(_ request: CheckoutRequest) async throws -> URL

    /// Fetches the current status of a previously created order.
    func status(orderId: String) async throws -> PaymentStatus

    /// Verifies the callback signature (always, for real) and decodes the
    /// signed `server_url` payload.
    func decodeCallback(data: String, signature: String) throws -> PaymentStatus
}

// MARK: - CheckoutRequest

/// What the provider needs to open a hosted payment page for one order.
struct CheckoutRequest: Sendable, Equatable {
    /// Provider `order_id`: our invoice id.
    let orderId: String
    let amount: Double
    let currency: String
    let description: String
    /// Non-nil means a recurring subscription (`action=subscribe`), nil a one-off payment (`action=pay`).
    let subscription: SubscriptionDuration?
    /// Browser redirect target after the flow; falls back to the gateway default.
    let resultURL: String?
    let language: String?
}

/// One purchased line, reduced to the primitives the checkout needs.
struct CheckoutLine: Sendable, Equatable {
    let amount: Double
    let quantity: Int
    let currencyName: String
    /// Set for subscription (plan) lines.
    let duration: SubscriptionDuration?
}

enum CheckoutRequestError: ValidationError, Equatable {
    case noLines
}

extension CheckoutRequest {

    /// Builds the request from an invoice and its lines (roadmap S09 mapping):
    /// amount = sum(amount x quantity), currency = first line's, description =
    /// `"Order #<orderId>"`, subscription = first line's duration.
    init(
        invoiceId: String,
        orderId: String,
        lines: [CheckoutLine],
        resultURL: String? = nil,
        language: String? = nil
    ) throws {
        guard let first = lines.first else { throw CheckoutRequestError.noLines }
        self.init(
            orderId: invoiceId,
            amount: lines.reduce(0) { $0 + $1.amount * Double($1.quantity) },
            currency: first.currencyName,
            description: "Order #\(orderId)",
            subscription: first.duration,
            resultURL: resultURL,
            language: language
        )
    }
}

// MARK: - PaymentStatus

/// Provider-agnostic projection of a provider status/callback payload. `status`
/// is the provider's raw vocabulary (mapping to invoice states is not done here).
struct PaymentStatus: Sendable, Equatable {
    let orderId: String?
    let status: String
    let action: String?
    let paymentId: String?
    let transactionId: String?
    let amount: Double?
    let currency: String?
    let errorCode: String?
    let errorDescription: String?
    /// For callbacks: the decoded JSON payload, unchanged, so it can be stored as-is.
    let rawPayload: String?
}

// MARK: - Errors

enum PaymentGatewayError: IntegrationError, Equatable {
    case notConfigured
    case invalidSignature
    case invalidPayload(String)
    case transport(String)
    case unexpectedResponse(String)
}
