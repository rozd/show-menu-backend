import Vapor

extension Application.CompositionRoot {

    // MARK: Subscriptions — Mappers

    var subscriptionMapper: SubscriptionMapper {
        resolver.resolve(\.subscriptionMapper) {
            SubscriptionMapper()
        }
    }

    // MARK: Subscriptions — Data Sources

    var subscriptionDataSourceFactory: DataSourceFactory<SubscriptionModel> {
        resolver.resolve(\.subscriptionDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreSubscriptionDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    // MARK: Subscriptions — Repositories

    var subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository> {
        resolver.resolve(\.subscriptionRepositoryFactory) {
            { [firestore] ctx in
                FirestoreSubscriptionRepository(
                    mapper: subscriptionMapper,
                    dataSourceFactory: subscriptionDataSourceFactory,
                    context: ctx,
                    directTransaction: { FirestoreTransaction.direct(firestore: firestore) }
                )
            }
        }
    }

    // MARK: Subscriptions — Use Cases

    var activateSubscriptionUseCaseFactory: UseCaseFactory<ActivateSubscriptionUseCase> {
        resolver.resolve(\.activateSubscriptionUseCaseFactory) {
            { [logger = app.logger] ctx in
                ActivateSubscriptionUseCase(
                    context: ctx,
                    invoiceRepositoryFactory: invoiceRepositoryFactory,
                    subscriptionRepositoryFactory: subscriptionRepositoryFactory,
                    logger: logger
                )
            }
        }
    }

    var suspendSubscriptionUseCaseFactory: UseCaseFactory<SuspendSubscriptionUseCase> {
        resolver.resolve(\.suspendSubscriptionUseCaseFactory) {
            { [logger = app.logger] ctx in
                SuspendSubscriptionUseCase(
                    context: ctx,
                    invoiceRepositoryFactory: invoiceRepositoryFactory,
                    subscriptionRepositoryFactory: subscriptionRepositoryFactory,
                    logger: logger
                )
            }
        }
    }

    var cancelSubscriptionUseCaseFactory: UseCaseFactory<CancelSubscriptionUseCase> {
        resolver.resolve(\.cancelSubscriptionUseCaseFactory) {
            { [logger = app.logger] ctx in
                CancelSubscriptionUseCase(
                    context: ctx,
                    invoiceRepositoryFactory: invoiceRepositoryFactory,
                    subscriptionRepositoryFactory: subscriptionRepositoryFactory,
                    logger: logger
                )
            }
        }
    }

    // MARK: Subscriptions — Domain Event Handlers

    var subscriptionInvoiceEventHandler: SubscriptionInvoiceEventHandler {
        resolver.resolve(\.subscriptionInvoiceEventHandler) {
            SubscriptionInvoiceEventHandler(
                unitOfWork: unitOfWork,
                activateUseCaseFactory: activateSubscriptionUseCaseFactory,
                suspendUseCaseFactory: suspendSubscriptionUseCaseFactory,
                cancelUseCaseFactory: cancelSubscriptionUseCaseFactory,
                logger: app.logger
            )
        }
    }

    // MARK: Subscriptions — Expiration job (S15)

    var expiringSubscriptionSource: any ExpiringSubscriptionSource {
        resolver.resolve(\.expiringSubscriptionSource) {
            FirestoreExpiringSubscriptionSource(directTransaction: { [firestore] in .direct(firestore: firestore) })
        }
    }

    var paidInvoiceSource: any PaidInvoiceSource {
        resolver.resolve(\.paidInvoiceSource) {
            FirestorePaidInvoiceSource(
                dataSourceFactory: invoiceDataSourceFactory,
                directTransaction: { [firestore] in FirestoreTransaction.direct(firestore: firestore) }
            )
        }
    }

    var expireSubscriptionUseCaseFactory: UseCaseFactory<ExpireSubscriptionUseCase> {
        resolver.resolve(\.expireSubscriptionUseCaseFactory) {
            { [logger = app.logger] ctx in
                ExpireSubscriptionUseCase(
                    context: ctx, subscriptionRepositoryFactory: subscriptionRepositoryFactory, logger: logger
                )
            }
        }
    }

    var reconcileSubscriptionUseCaseFactory: UseCaseFactory<ReconcileSubscriptionUseCase> {
        resolver.resolve(\.reconcileSubscriptionUseCaseFactory) {
            { [logger = app.logger, activate = activateSubscriptionUseCaseFactory] ctx in
                ReconcileSubscriptionUseCase(
                    context: ctx,
                    invoiceRepositoryFactory: invoiceRepositoryFactory,
                    subscriptionRepositoryFactory: subscriptionRepositoryFactory,
                    activate: activate(ctx),
                    logger: logger
                )
            }
        }
    }

    var checkExpiredSubscriptionsJob: CheckExpiredSubscriptionsJob {
        resolver.resolve(\.checkExpiredSubscriptionsJob) {
            CheckExpiredSubscriptionsJob(
                unitOfWork: unitOfWork,
                subscriptions: expiringSubscriptionSource,
                invoices: paidInvoiceSource,
                expireUseCaseFactory: expireSubscriptionUseCaseFactory,
                reconcileUseCaseFactory: reconcileSubscriptionUseCaseFactory,
                logger: app.logger
            )
        }
    }
}
