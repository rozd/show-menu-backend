import LiqPayClientVapor
import Vapor

extension Application.CompositionRoot {

    // MARK: Billing — Payment Gateway

    /// Lazy: nothing here runs until the first `app.deps.paymentGateway` access, so the
    /// app boots with no `LIQPAY_*` environment at all (the gateway then answers
    /// `notConfigured`, or is the fake one in development/testing).
    var paymentGateway: any PaymentGateway {
        resolver.resolve(\.paymentGateway) {
            let selection = LiqPayGatewaySelection.select(
                environment: ProcessInfo.processInfo.environment,
                appEnvironment: app.environment
            )
            switch selection {
            case .fake(let configuration):
                let gateway = FakePaymentGateway(configuration: configuration)
                app.logger.info("LiqPay: fake gateway (no network)", metadata: [
                    "sandbox": .string("\(gateway.isSandbox)")
                ])
                return gateway

            case .live(let configuration):
                let transport = AsyncHTTPClientLiqPayCheckoutTransport()
                app.lifecycle.use(LiqPayCheckoutTransportShutdown(transport: transport))
                let gateway = LiqPayPaymentGateway(
                    configuration: configuration,
                    apiTransport: LiqPayVaporTransport(client: client),
                    checkoutTransport: transport,
                    logger: app.logger
                )
                app.logger.info("LiqPay configured", metadata: [
                    "sandbox": .string("\(gateway.isSandbox)")
                ])
                return gateway

            case .unconfigured:
                app.logger.warning("LIQPAY_PUBLIC_KEY/LIQPAY_PRIVATE_KEY not set — payment calls disabled")
                return UnconfiguredPaymentGateway()
            }
        }
    }
}
