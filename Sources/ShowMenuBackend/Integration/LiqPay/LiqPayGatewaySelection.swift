import Foundation
import Vapor

/// Which `PaymentGateway` to bind, decided purely from the environment.
enum LiqPayGatewaySelection: Equatable {
    /// Development/testing without keys: no network, fixed test keypair.
    case fake(LiqPayGatewayConfiguration)
    /// Both keys present.
    case live(LiqPayGatewayConfiguration)
    /// Keys missing outside development/testing: boot, but fail payment calls (and warn).
    case unconfigured

    /// - Parameters:
    ///   - environment: `LIQPAY_PUBLIC_KEY`, `LIQPAY_PRIVATE_KEY`, `LIQPAY_CALLBACK_URL`,
    ///     `LIQPAY_RESULT_URL`, `LIQPAY_API_URL`.
    ///   - appEnvironment: the Vapor environment. Fake is only ever chosen for
    ///     `.development` and `.testing` — never in production (or any other environment).
    static func select(environment: [String: String], appEnvironment: Vapor.Environment) -> LiqPayGatewaySelection {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        let apiBase = value("LIQPAY_API_URL").flatMap { URL(string: $0) } ?? LiqPayGatewayConfiguration.defaultAPIBaseURL
        let callback = value("LIQPAY_CALLBACK_URL")
        let result = value("LIQPAY_RESULT_URL")

        if let publicKey = value("LIQPAY_PUBLIC_KEY"), let privateKey = value("LIQPAY_PRIVATE_KEY") {
            return .live(LiqPayGatewayConfiguration(
                publicKey: publicKey, privateKey: privateKey,
                callbackURL: callback, resultURL: result, apiBaseURL: apiBase
            ))
        }
        guard appEnvironment == .development || appEnvironment == .testing else { return .unconfigured }
        return .fake(FakePaymentGateway.testConfiguration(from: LiqPayGatewayConfiguration(
            publicKey: "", privateKey: "", callbackURL: callback, resultURL: result, apiBaseURL: apiBase
        )))
    }
}
