import Foundation
import LiqPayClient

/// Emulator-only `PaymentGateway`: no network, ever.
///
/// - `checkout` signs the real envelope and returns a deterministic URL
///   `<base>/3/checkout?data=...&signature=...` without contacting LiqPay.
/// - `status` reports `processing`.
/// - `decodeCallback` performs REAL signature verification with the configured
///   keys, so emulator e2e tests can sign callbacks themselves.
///
/// Never bound outside the emulator: a fake payment page in production would be dangerous.
struct FakePaymentGateway: PaymentGateway {

    /// Documented test keypair used in the emulator when no `LIQPAY_*` keys are set.
    /// Obviously fake; the `sandbox_` prefix marks it as sandbox.
    static let emulatorPublicKey = "sandbox_showmenu_emulator_public"
    static let emulatorPrivateKey = "sandbox_showmenu_emulator_private"

    /// `server_url` placeholder when `LIQPAY_CALLBACK_URL` is unset in the emulator.
    static let placeholderCallbackURL = "http://localhost:8080/api/v1/payments/liqpay/callback"

    let configuration: LiqPayGatewayConfiguration
    let now: @Sendable () -> Date

    init(configuration: LiqPayGatewayConfiguration, now: @escaping @Sendable () -> Date = { .now }) {
        self.configuration = configuration
        self.now = now
    }

    /// The configuration for an emulator without keys in the environment.
    static func testConfiguration(from base: LiqPayGatewayConfiguration? = nil) -> LiqPayGatewayConfiguration {
        LiqPayGatewayConfiguration(
            publicKey: emulatorPublicKey,
            privateKey: emulatorPrivateKey,
            callbackURL: base?.callbackURL,
            resultURL: base?.resultURL,
            apiBaseURL: base?.apiBaseURL ?? LiqPayGatewayConfiguration.defaultAPIBaseURL
        )
    }

    var isSandbox: Bool { configuration.credentials.isSandbox }

    func checkout(_ request: CheckoutRequest) async throws -> URL {
        let envelope = try LiqPayCheckoutEnvelope.make(
            request: request,
            credentials: configuration.credentials,
            serverURL: configuration.callbackURL ?? Self.placeholderCallbackURL,
            defaultResultURL: configuration.resultURL,
            now: now()
        )
        let query = [("data", envelope.data), ("signature", envelope.signature)]
            .map { "\($0)=\(AsyncHTTPClientLiqPayCheckoutTransport.percentEncode($1))" }
            .joined(separator: "&")
        guard let url = URL(string: "\(configuration.checkoutURL.absoluteString)?\(query)") else {
            throw PaymentGatewayError.unexpectedResponse("Could not build fake checkout URL")
        }
        return url
    }

    func status(orderId: String) async throws -> PaymentStatus {
        PaymentStatus(
            orderId: orderId, status: "processing", action: nil, paymentId: nil, transactionId: nil,
            amount: nil, currency: nil, errorCode: nil, errorDescription: nil, rawPayload: nil
        )
    }

    func decodeCallback(data: String, signature: String) throws -> PaymentStatus {
        // Verification-only client: it never performs I/O here.
        let client = LiqPayClient.Client(credentials: configuration.credentials, transport: NoNetworkTransport())
        do {
            let response = try client.webhooks.decode(data: data, signature: signature)
            let raw = Data(base64Encoded: data).map { String(decoding: $0, as: UTF8.self) }
            return PaymentStatus(response, rawPayload: raw)
        } catch {
            throw LiqPayPaymentGateway.map(error)
        }
    }
}

private struct NoNetworkTransport: LiqPayTransport {
    func send(_ request: LiqPayTransportRequest) async throws -> LiqPayTransportResponse {
        throw PaymentGatewayError.notConfigured
    }
}
