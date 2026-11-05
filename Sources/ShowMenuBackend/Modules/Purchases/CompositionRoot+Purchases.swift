import LiqPayClientVapor
import Vapor

extension Application.CompositionRoot {

    // MARK: Purchases — Mappers

    var orderMapper: OrderMapper {
        resolver.resolve(\.orderMapper) {
            OrderMapper()
        }
    }

    var invoiceMapper: InvoiceMapper {
        resolver.resolve(\.invoiceMapper) {
            InvoiceMapper()
        }
    }

    var checkoutSessionMapper: CheckoutSessionMapper {
        resolver.resolve(\.checkoutSessionMapper) {
            CheckoutSessionMapper()
        }
    }

    // MARK: Purchases — Data Sources

    var orderDataSourceFactory: DataSourceFactory<OrderModel> {
        resolver.resolve(\.orderDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreOrderDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    var invoiceDataSourceFactory: DataSourceFactory<InvoiceModel> {
        resolver.resolve(\.invoiceDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreInvoiceDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    var checkoutSessionDataSourceFactory: DataSourceFactory<CheckoutSessionModel> {
        resolver.resolve(\.checkoutSessionDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreCheckoutSessionDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    // MARK: Purchases — Repositories

    var orderRepositoryFactory: RepositoryFactory<any OrderRepository> {
        resolver.resolve(\.orderRepositoryFactory) {
            { ctx in
                FirestoreOrderRepository(
                    mapper: orderMapper,
                    dataSourceFactory: orderDataSourceFactory,
                    context: ctx
                )
            }
        }
    }

    var invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository> {
        resolver.resolve(\.invoiceRepositoryFactory) {
            { ctx in
                FirestoreInvoiceRepository(
                    mapper: invoiceMapper,
                    dataSourceFactory: invoiceDataSourceFactory,
                    context: ctx
                )
            }
        }
    }

    var checkoutLockDataSourceFactory: DataSourceFactory<CheckoutLockModel> {
        resolver.resolve(\.checkoutLockDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreCheckoutLockDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    // MARK: Purchases — Use Cases, Handlers, Flow

    var purchaseSubscriptionUseCaseFactory: UseCaseFactory<PurchaseSubscriptionUseCase> {
        resolver.resolve(\.purchaseSubscriptionUseCaseFactory) {
            { [logger = app.logger, firestore] ctx in
                PurchaseSubscriptionUseCase(
                    context: ctx,
                    accountDataSourceFactory: accountDataSourceFactory,
                    accountMapper: accountMapper,
                    permissionStoreFactory: accountPermissionStoreFactory,
                    ability: AccountMemberAbility(),
                    planRepositoryFactory: planRepositoryFactory,
                    userRepositoryFactory: userRepositoryFactory,
                    orderRepositoryFactory: orderRepositoryFactory,
                    invoiceRepositoryFactory: invoiceRepositoryFactory,
                    sessionDataSourceFactory: checkoutSessionDataSourceFactory,
                    sessionMapper: checkoutSessionMapper,
                    lockDataSourceFactory: checkoutLockDataSourceFactory,
                    directTransaction: { FirestoreTransaction.direct(firestore: firestore) },
                    logger: logger
                )
            }
        }
    }

    var purchaseSubscriptionCommandHandler: PurchaseSubscriptionCommandHandler {
        resolver.resolve(\.purchaseSubscriptionCommandHandler) {
            PurchaseSubscriptionCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: purchaseSubscriptionUseCaseFactory,
                idempotency: IdempotencyComponents(
                    storeFactory: idempotencyStoreFactory,
                    configuration: idempotencyConfiguration
                ),
                logger: app.logger
            )
        }
    }

    var checkoutInitiator: CheckoutInitiator {
        resolver.resolve(\.checkoutInitiator) {
            CheckoutInitiator(
                unitOfWork: unitOfWork,
                gateway: paymentGateway,
                sessionDataSourceFactory: checkoutSessionDataSourceFactory,
                sessionMapper: checkoutSessionMapper,
                invoiceDataSourceFactory: invoiceDataSourceFactory,
                invoiceMapper: invoiceMapper,
                invoiceRepositoryFactory: invoiceRepositoryFactory,
                orderRepositoryFactory: orderRepositoryFactory,
                directTransaction: { [firestore] in FirestoreTransaction.direct(firestore: firestore) },
                logger: app.logger
            )
        }
    }

    var purchaseSubscriptionFlow: PurchaseSubscriptionFlow {
        resolver.resolve(\.purchaseSubscriptionFlow) {
            PurchaseSubscriptionFlow(
                purchase: purchaseSubscriptionCommandHandler,
                checkout: checkoutInitiator
            )
        }
    }

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
