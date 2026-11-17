import Foundation
import LiqPayClient

/// Development/testing `PaymentGateway`: no network, ever.
///
/// - `checkout` signs the real envelope and returns a deterministic URL
///   `<base>/3/checkout?data=...&signature=...` without contacting LiqPay.
/// - `status` reports `processing`.
/// - `decodeCallback` performs REAL signature verification with the configured
///   keys, so end-to-end tests can sign callbacks themselves.
///
/// Never bound in production: a fake payment page there would be dangerous
/// (see `LiqPayGatewaySelection`).
struct FakePaymentGateway: PaymentGateway {

    /// Documented test keypair used when no `LIQPAY_*` keys are set.
    /// Obviously fake; the `sandbox_` prefix marks it as sandbox.
    static let testPublicKey = "sandbox_showmenu_dev_public"
    static let testPrivateKey = "sandbox_showmenu_dev_private"

    /// `server_url` placeholder when `LIQPAY_CALLBACK_URL` is unset.
    static let placeholderCallbackURL = "http://localhost:8080/api/v1/payments/liqpay/callback"

    let configuration: LiqPayGatewayConfiguration

    init(configuration: LiqPayGatewayConfiguration) {
        self.configuration = configuration
    }

    /// The configuration for a development run without keys in the environment.
    static func testConfiguration(from base: LiqPayGatewayConfiguration? = nil) -> LiqPayGatewayConfiguration {
        LiqPayGatewayConfiguration(
            publicKey: testPublicKey,
            privateKey: testPrivateKey,
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
            defaultResultURL: configuration.resultURL
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
