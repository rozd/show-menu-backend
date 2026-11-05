import Foundation

/// Which `PaymentGateway` to bind, decided purely from the environment.
enum LiqPayGatewaySelection: Equatable {
    /// Emulator: no network. Uses env keys when present, else the fixed test keypair.
    case fake(LiqPayGatewayConfiguration)
    /// Both keys present outside the emulator.
    case live(LiqPayGatewayConfiguration)
    /// Keys missing outside the emulator: boot, but fail payment calls (and warn).
    case unconfigured

    /// - Parameters:
    ///   - environment: `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY`, `LIQPAY_CALLBACK_URL`,
    ///     `LIQPAY_RESULT_URL`, `LIQPAY_API_URL`.
    ///   - isEmulator: deliberately never falls back to Fake outside the emulator.
    static func select(environment: [String: String], isEmulator: Bool) -> LiqPayGatewaySelection {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        let apiBase = value("LIQPAY_API_URL").flatMap { URL(string: $0) } ?? LiqPayGatewayConfiguration.defaultAPIBaseURL
        let callback = value("LIQPAY_CALLBACK_URL")
        let result = value("LIQPAY_RESULT_URL")

        if let publicKey = value("LIQPAY_PUBLIC_KEY"), let privateKey = value("LIQPAY_PRIVATE_KEY") {
            let configuration = LiqPayGatewayConfiguration(
                publicKey: publicKey, privateKey: privateKey,
                callbackURL: callback, resultURL: result, apiBaseURL: apiBase
            )
            return isEmulator ? .fake(configuration) : .live(configuration)
        }
        guard isEmulator else { return .unconfigured }
        return .fake(FakePaymentGateway.testConfiguration(from: LiqPayGatewayConfiguration(
            publicKey: "", privateKey: "", callbackURL: callback, resultURL: result, apiBaseURL: apiBase
        )))
    }
}
