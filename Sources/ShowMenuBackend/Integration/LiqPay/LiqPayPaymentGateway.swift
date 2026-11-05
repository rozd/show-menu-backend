import Foundation
import LiqPayClient
import Logging

/// Env-derived settings shared by the Live and Fake gateways.
struct LiqPayGatewayConfiguration: Sendable, Equatable {
    static let defaultAPIBaseURL = URL(string: "https://www.liqpay.ua/api")!

    let publicKey: String
    let privateKey: String
    /// `server_url`: where LiqPay POSTs the payment result.
    let callbackURL: String?
    /// Default `result_url` when a request carries none.
    let resultURL: String?
    /// `LIQPAY_API_URL`; request = `<base>/request`, checkout = `<base>/3/checkout`.
    let apiBaseURL: URL

    var credentials: LiqPayCredentials {
        LiqPayCredentials(publicKey: PublicKey(publicKey), privateKey: PrivateKey(privateKey))
    }

    var checkoutURL: URL { apiBaseURL.appendingPathComponent("3/checkout") }
    var requestURL: URL { apiBaseURL.appendingPathComponent("request") }
}

/// `PaymentGateway` adapter over the `LiqPayClient` package.
///
/// `status` and `decodeCallback` go through the package; `checkout` signs the
/// hosted-checkout form itself and POSTs it through `LiqPayCheckoutTransport`
/// (the package cannot read the redirect `Location`).
///
/// Resilience: `RetryPolicy` (outermost) around a shared `CircuitBreaker` around
/// the network call. Only transient failures (transport errors, 5xx) are retried
/// and counted by the breaker; 4xx, signature and decoding failures are not.
struct LiqPayPaymentGateway: PaymentGateway {

    let client: LiqPayClient.Client
    let configuration: LiqPayGatewayConfiguration
    let checkoutTransport: any LiqPayCheckoutTransport
    let retryPolicy: RetryPolicy
    let breaker: CircuitBreaker
    let now: @Sendable () -> Date

    init(
        configuration: LiqPayGatewayConfiguration,
        apiTransport: any LiqPayTransport,
        checkoutTransport: any LiqPayCheckoutTransport,
        retryPolicy: RetryPolicy = .liqPay(),
        breaker: CircuitBreaker = CircuitBreaker(),
        now: @escaping @Sendable () -> Date = { .now },
        logger: Logger = Logger(label: "liqpay-client")
    ) {
        self.configuration = configuration
        self.client = LiqPayClient.Client(
            credentials: configuration.credentials,
            configuration: LiqPayConfiguration(
                endpoint: configuration.requestURL,
                callbackURL: configuration.callbackURL.flatMap { URL(string: $0) }
            ),
            transport: apiTransport,
            logger: logger
        )
        self.checkoutTransport = checkoutTransport
        self.retryPolicy = retryPolicy
        self.breaker = breaker
        self.now = now
    }

    var isSandbox: Bool { client.credentials.isSandbox }

    func checkout(_ request: CheckoutRequest) async throws -> URL {
        guard let serverURL = configuration.callbackURL else {
            throw PaymentGatewayError.notConfigured
        }
        let envelope = try LiqPayCheckoutEnvelope.make(
            request: request,
            credentials: client.credentials,
            serverURL: serverURL,
            defaultResultURL: configuration.resultURL,
            now: now()
        )
        let url = configuration.checkoutURL
        let transport = checkoutTransport
        return try await guarded {
            let response: LiqPayCheckoutResponse
            do {
                response = try await transport.post(
                    url: url,
                    form: ["data": envelope.data, "signature": envelope.signature]
                )
            } catch let error as PaymentGatewayError {
                throw error
            } catch {
                throw PaymentGatewayError.transport(String(describing: error))
            }
            return try Self.pageURL(from: response)
        }
    }

    func status(orderId: String) async throws -> PaymentStatus {
        let client = client
        return try await guarded {
            do {
                let response = try await client.payments.status(orderId: OrderId(orderId))
                return PaymentStatus(response, rawPayload: nil)
            } catch let error as LiqPayClientError {
                // An undecodable *response* to our own call (e.g. an HTML 5xx
                // page) is the provider's fault (502), not a bad inbound payload.
                if case .decodingFailed(_, let preview) = error {
                    throw PaymentGatewayError.unexpectedResponse(preview)
                }
                throw Self.map(error)
            }
        }
    }

    func decodeCallback(data: String, signature: String) throws -> PaymentStatus {
        do {
            let response = try client.webhooks.decode(data: data, signature: signature)
            let raw = Data(base64Encoded: data).map { String(decoding: $0, as: UTF8.self) }
            return PaymentStatus(response, rawPayload: raw)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Checkout response

    /// 3xx + `Location` is the payment page. Everything else is unexpected;
    /// 5xx is additionally transient (retryable).
    static func pageURL(from response: LiqPayCheckoutResponse) throws -> URL {
        switch response.statusCode {
        case 300..<400:
            guard let location = response.location, let url = URL(string: location) else {
                throw PaymentGatewayError.unexpectedResponse(
                    "Checkout redirect (\(response.statusCode)) without a usable Location header: \(response.bodyPreview)"
                )
            }
            return url
        case 500..<600:
            throw PaymentGatewayError.transport(
                "Checkout failed with HTTP \(response.statusCode): \(response.bodyPreview)"
            )
        default:
            throw PaymentGatewayError.unexpectedResponse(
                "Checkout answered HTTP \(response.statusCode), expected a redirect: \(response.bodyPreview)"
            )
        }
    }

    // MARK: - Resilience

    /// Retry (outer) -> breaker (inner). Non-transient failures travel as a value
    /// through the breaker so they neither trip it nor get retried.
    private func guarded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let breaker = breaker
        do {
            let outcome: Result<T, PaymentGatewayError> = try await retryPolicy.execute {
                try await breaker.execute {
                    do {
                        return .success(try await operation())
                    } catch let error as PaymentGatewayError where !error.isTransient {
                        return .failure(error)
                    }
                }
            }
            return try outcome.get()
        } catch let open as CircuitBreakerOpenError {
            throw PaymentGatewayError.transport("LiqPay circuit open: \(open)")
        }
    }

    // MARK: - Mapping

    static func map(_ error: any Error) -> PaymentGatewayError {
        if let error = error as? PaymentGatewayError { return error }
        guard let error = error as? LiqPayClientError else {
            return .unexpectedResponse(String(describing: error))
        }
        switch error {
        case .notConfigured:
            return .notConfigured
        case .invalidSignature:
            return .invalidSignature
        case .invalidPayloadEncoding:
            return .invalidPayload("Callback data is not valid base64")
        case .decodingFailed(_, let preview):
            return .invalidPayload(preview)
        case .transportFailure(let underlying):
            return .transport(String(describing: underlying))
        case .encodingFailed, .unexpected:
            return .unexpectedResponse(String(describing: error))
        }
    }
}

// MARK: - Support

extension PaymentGatewayError {
    /// Worth retrying / counting against the circuit breaker.
    var isTransient: Bool {
        if case .transport = self { return true }
        return false
    }
}

extension RetryPolicy {
    /// 3 attempts with capped exponential backoff; retries only transient gateway failures.
    static func liqPay(backoff: Backoff = .exponential(initial: 0.5, multiplier: 2, cap: 4)) -> RetryPolicy {
        RetryPolicy(
            maxAttempts: 3,
            backoff: backoff,
            shouldRetry: { ($0 as? PaymentGatewayError)?.isTransient ?? false }
        )
    }
}

extension PaymentStatus {
    init(_ response: LiqPayResponse, rawPayload: String?) {
        self.init(
            orderId: response.orderId?.rawValue,
            status: response.status ?? response.result ?? "unknown",
            action: response.action,
            paymentId: response.paymentId.map(String.init),
            transactionId: response.transactionId.map(String.init),
            amount: response.amount,
            currency: response.currency,
            errorCode: response.errCode ?? response.code,
            errorDescription: response.errDescription,
            rawPayload: rawPayload
        )
    }
}
