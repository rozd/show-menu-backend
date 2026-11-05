import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("LiqPayGatewaySelection")
struct LiqPayGatewaySelectionTests {

    private let keys = ["LIQPAY_PUBLIC_KEY": "pub_test", "LIQPAY_PRIVATE_KEY": "priv_test"]

    @Test("emulator without keys: fake with the test keypair")
    func emulatorNoKeys() {
        guard case .fake(let configuration) = LiqPayGatewaySelection.select(environment: [:], isEmulator: true) else {
            Issue.record("expected fake"); return
        }
        #expect(configuration.publicKey == FakePaymentGateway.emulatorPublicKey)
        #expect(configuration.privateKey == FakePaymentGateway.emulatorPrivateKey)
    }

    @Test("emulator with keys: fake with the env keys")
    func emulatorWithKeys() {
        guard case .fake(let configuration) = LiqPayGatewaySelection.select(environment: keys, isEmulator: true) else {
            Issue.record("expected fake"); return
        }
        #expect(configuration.publicKey == "pub_test")
        #expect(configuration.privateKey == "priv_test")
    }

    @Test("non-emulator with both keys: live, env URLs applied")
    func liveWithKeys() {
        let env = keys.merging([
            "LIQPAY_CALLBACK_URL": "https://example.test/cb",
            "LIQPAY_RESULT_URL": "https://example.test/done",
            "LIQPAY_API_URL": "https://sandbox.example.test/api",
        ]) { $1 }
        guard case .live(let configuration) = LiqPayGatewaySelection.select(environment: env, isEmulator: false) else {
            Issue.record("expected live"); return
        }
        #expect(configuration.callbackURL == "https://example.test/cb")
        #expect(configuration.resultURL == "https://example.test/done")
        #expect(configuration.apiBaseURL.absoluteString == "https://sandbox.example.test/api")
    }

    @Test("non-emulator: default API base when LIQPAY_API_URL is unset")
    func defaultBase() {
        guard case .live(let configuration) = LiqPayGatewaySelection.select(environment: keys, isEmulator: false) else {
            Issue.record("expected live"); return
        }
        #expect(configuration.apiBaseURL == LiqPayGatewayConfiguration.defaultAPIBaseURL)
    }

    @Test("non-emulator with missing or empty keys: unconfigured, never fake")
    func unconfigured() {
        #expect(LiqPayGatewaySelection.select(environment: [:], isEmulator: false) == .unconfigured)
        #expect(LiqPayGatewaySelection.select(environment: ["LIQPAY_PUBLIC_KEY": "pub_test"], isEmulator: false) == .unconfigured)
        #expect(LiqPayGatewaySelection.select(
            environment: ["LIQPAY_PUBLIC_KEY": "pub_test", "LIQPAY_PRIVATE_KEY": ""], isEmulator: false
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
