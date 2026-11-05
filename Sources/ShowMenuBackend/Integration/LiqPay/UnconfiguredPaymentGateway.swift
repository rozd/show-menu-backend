import Foundation

/// Bound when LIQPAY_* keys are absent outside the emulator so the app still boots;
/// payment endpoints fail with `notConfigured` instead of crashing startup.
struct UnconfiguredPaymentGateway: PaymentGateway {
    let isSandbox = true

    func checkout(_ request: CheckoutRequest) async throws -> URL {
        throw PaymentGatewayError.notConfigured
    }

    func status(orderId: String) async throws -> PaymentStatus {
        throw PaymentGatewayError.notConfigured
    }

    func decodeCallback(data: String, signature: String) throws -> PaymentStatus {
        throw PaymentGatewayError.notConfigured
    }
}
