import Foundation

/// Port to the external payment provider. Implemented by the LiqPay adapter in
/// `Integration/LiqPay`; faked in tests and in development.
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

/// What kind of payment a checkout opens.
enum CheckoutKind: Sendable, Equatable {
    /// A recurring monthly charge (`action=subscribe`), first charge on `startDate`.
    case monthlySubscription(startDate: Date)
    /// A single payment (`action=pay`).
    case oneOff
}

/// What the provider needs to open a hosted payment page for one order.
struct CheckoutRequest: Sendable, Equatable {
    /// Provider `order_id`.
    let orderId: String
    let money: Money
    let description: String
    let kind: CheckoutKind
    /// Browser redirect target after the flow; falls back to the gateway default.
    let resultURL: String?
    let language: String?

    init(
        orderId: String,
        money: Money,
        description: String,
        kind: CheckoutKind,
        resultURL: String? = nil,
        language: String? = nil
    ) {
        self.orderId = orderId
        self.money = money
        self.description = description
        self.kind = kind
        self.resultURL = resultURL
        self.language = language
    }
}

// MARK: - PaymentStatus

/// Provider-agnostic projection of a provider status/callback payload. `status`
/// is the provider's raw vocabulary (no mapping to domain states is done here).
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
