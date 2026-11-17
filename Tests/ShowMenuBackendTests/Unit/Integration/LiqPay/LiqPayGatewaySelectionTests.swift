import Foundation
import Testing
import Vapor
@testable import ShowMenuBackend

@Suite("LiqPayGatewaySelection")
struct LiqPayGatewaySelectionTests {

    private let keys = ["LIQPAY_PUBLIC_KEY": "pub_test", "LIQPAY_PRIVATE_KEY": "priv_test"]

    @Test("development and testing without keys: fake with the test keypair",
          arguments: [Vapor.Environment.development, .testing])
    func fakeNoKeys(environment: Vapor.Environment) {
        guard case .fake(let configuration) = LiqPayGatewaySelection.select(environment: [:], appEnvironment: environment) else {
            Issue.record("expected fake"); return
        }
        #expect(configuration.publicKey == FakePaymentGateway.testPublicKey)
        #expect(configuration.privateKey == FakePaymentGateway.testPrivateKey)
    }

    @Test("both keys: live in every environment, env keys applied",
          arguments: [Vapor.Environment.development, .testing, .production])
    func liveWithKeysAnyEnvironment(environment: Vapor.Environment) {
        guard case .live(let configuration) = LiqPayGatewaySelection.select(environment: keys, appEnvironment: environment) else {
            Issue.record("expected live"); return
        }
        #expect(configuration.publicKey == "pub_test")
        #expect(configuration.privateKey == "priv_test")
    }

    @Test("production without keys is unconfigured, never fake",
          arguments: [Vapor.Environment.production, .custom(name: "staging")])
    func neverFakeOutsideDevOrTesting(environment: Vapor.Environment) {
        #expect(LiqPayGatewaySelection.select(environment: [:], appEnvironment: environment) == .unconfigured)
    }

    @Test("production with both keys: live, env URLs applied")
    func liveWithKeys() {
        let env = keys.merging([
            "LIQPAY_CALLBACK_URL": "https://example.test/cb",
            "LIQPAY_RESULT_URL": "https://example.test/done",
            "LIQPAY_API_URL": "https://sandbox.example.test/api",
        ]) { $1 }
        guard case .live(let configuration) = LiqPayGatewaySelection.select(environment: env, appEnvironment: .production) else {
            Issue.record("expected live"); return
        }
        #expect(configuration.callbackURL == "https://example.test/cb")
        #expect(configuration.resultURL == "https://example.test/done")
        #expect(configuration.apiBaseURL.absoluteString == "https://sandbox.example.test/api")
    }

    @Test("production: default API base when LIQPAY_API_URL is unset")
    func defaultBase() {
        guard case .live(let configuration) = LiqPayGatewaySelection.select(environment: keys, appEnvironment: .production) else {
            Issue.record("expected live"); return
        }
        #expect(configuration.apiBaseURL == LiqPayGatewayConfiguration.defaultAPIBaseURL)
    }

    @Test("production with missing or empty keys: unconfigured, never fake")
    func unconfigured() {
        #expect(LiqPayGatewaySelection.select(environment: [:], appEnvironment: .production) == .unconfigured)
        #expect(LiqPayGatewaySelection.select(environment: ["LIQPAY_PUBLIC_KEY": "pub_test"], appEnvironment: .production) == .unconfigured)
        #expect(LiqPayGatewaySelection.select(
            environment: ["LIQPAY_PUBLIC_KEY": "pub_test", "LIQPAY_PRIVATE_KEY": ""], appEnvironment: .production
        ) == .unconfigured)
    }

    @Test("unconfigured gateway throws notConfigured everywhere")
    func unconfiguredGateway() async {
        let gateway = UnconfiguredPaymentGateway()
        await #expect(throws: PaymentGatewayError.notConfigured) { _ = try await gateway.checkout(LiqPayFixtures.request()) }
        await #expect(throws: PaymentGatewayError.notConfigured) { _ = try await gateway.status(orderId: "x") }
        #expect(throws: PaymentGatewayError.notConfigured) { _ = try gateway.decodeCallback(data: "", signature: "") }
    }
}
