import LiqPayClientVapor
import Vapor

extension Application.CompositionRoot {

    // MARK: Purchases — Payment Gateway

    var paymentGateway: any PaymentGateway {
        resolver.resolve(\.paymentGateway) {
            let selection = LiqPayGatewaySelection.select(
                environment: ProcessInfo.processInfo.environment,
                isEmulator: config.environment.isEmulator
            )
            switch selection {
            case .fake(let configuration):
                let gateway = FakePaymentGateway(configuration: configuration)
                app.logger.info("LiqPay: fake gateway (emulator, no network)", metadata: [
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
                app.logger.warning("LIQPAY_PUBLIC_KEY/LIQPAY_PRIVATE_KEY not set — payment endpoints disabled")
                return UnconfiguredPaymentGateway()
            }
        }
    }
}
