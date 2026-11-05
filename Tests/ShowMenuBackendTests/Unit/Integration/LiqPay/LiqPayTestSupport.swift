import Crypto
import Testing
import Foundation
import LiqPayClient
@testable import ShowMenuBackend

/// Obviously fake keys; never real credentials.
enum LiqPayFixtures {
    static let publicKey = "sandbox_test_public"
    static let privateKey = "test_private_key"
    static let callbackURL = "https://example.test/liqpay/callback"
    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

    static func configuration(
        callbackURL: String? = LiqPayFixtures.callbackURL,
        resultURL: String? = nil,
        apiBaseURL: URL = LiqPayGatewayConfiguration.defaultAPIBaseURL
    ) -> LiqPayGatewayConfiguration {
        LiqPayGatewayConfiguration(
            publicKey: publicKey, privateKey: privateKey,
            callbackURL: callbackURL, resultURL: resultURL, apiBaseURL: apiBaseURL
        )
    }

    static func request(
        orderId: String = "inv-1",
        amount: Double = 19.99,
        subscription: SubscriptionDuration? = nil,
        resultURL: String? = nil,
        language: String? = nil
    ) -> CheckoutRequest {
        CheckoutRequest(
            orderId: orderId, amount: amount, currency: "UAH", description: "Order #o-1",
            subscription: subscription, resultURL: resultURL, language: language
        )
    }

    /// Decodes an envelope's `data` back into its JSON object.
    static func decode(_ data: String) throws -> [String: Any] {
        let bytes = try #require(Data(base64Encoded: data))
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    /// Signs arbitrary JSON the way LiqPay signs a callback.
    static func callback(json: String, privateKey: String = LiqPayFixtures.privateKey) -> (data: String, signature: String) {
        let data = Data(json.utf8).base64EncodedString()
        return (data, LiqPaySigner.sign(privateKey: PrivateKey(privateKey), data: data))
    }
}

/// Scripted checkout transport: replays `script` in order (last entry repeats); counts calls.
final class StubCheckoutTransport: LiqPayCheckoutTransport, @unchecked Sendable {
    enum Step {
        case response(LiqPayCheckoutResponse)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var script: [Step]
    private(set) var calls: [(url: URL, form: [String: String])] = []

    init(_ script: [Step]) { self.script = script }

    var callCount: Int { lock.withLock { calls.count } }

    func post(url: URL, form: [String: String]) async throws -> LiqPayCheckoutResponse {
        let step: Step = lock.withLock {
            calls.append((url, form))
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        switch step {
        case .response(let response): return response
        case .failure(let error): return try { throw error }()
        }
    }

    static func redirect(_ location: String? = "https://pay.example.test/page", status: Int = 302) -> Step {
        .response(LiqPayCheckoutResponse(statusCode: status, location: location, bodyPreview: ""))
    }

    static func status(_ code: Int, body: String = "") -> Step {
        .response(LiqPayCheckoutResponse(statusCode: code, location: nil, bodyPreview: body))
    }
}

/// `LiqPayTransport` returning a fixed body; records requests.
final class StubAPITransport: LiqPayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String
    private let error: (any Error)?
    private var _requests: [LiqPayTransportRequest] = []

    init(body: String = "{}", error: (any Error)? = nil) {
        self.body = body
        self.error = error
    }

    var requests: [LiqPayTransportRequest] { lock.withLock { _requests } }

    func send(_ request: LiqPayTransportRequest) async throws -> LiqPayTransportResponse {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return LiqPayTransportResponse(statusCode: 200, body: Data(body.utf8))
    }
}

struct StubNetworkError: Error {}
