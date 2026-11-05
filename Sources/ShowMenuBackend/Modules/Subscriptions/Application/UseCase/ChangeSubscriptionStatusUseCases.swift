import Foundation
import Logging

/// `invoice.failed` / `invoice.charge_failed` -> `Suspend("Payment failed")`.
struct SuspendSubscriptionUseCase: UseCase {
    struct Params: Sendable {
        let invoiceId: Invoice.Id
        let reason: String
    }

    let context: any UnitOfWorkContext
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository>
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        context: any UnitOfWorkContext,
        invoiceRepositoryFactory: @escaping RepositoryFactory<any InvoiceRepository>,
        subscriptionRepositoryFactory: @escaping RepositoryFactory<any SubscriptionRepository>,
        now: @escaping @Sendable () -> Date = { .now },
        logger: Logger
    ) {
        self.context = context
        self.invoiceRepositoryFactory = invoiceRepositoryFactory
        self.subscriptionRepositoryFactory = subscriptionRepositoryFactory
        self.now = now
        self.logger = logger
    }

    func execute(params: Params) async throws {
        try await SubscriptionStatusChange.apply(
            action: "suspend", invoiceId: params.invoiceId, context: context,
            invoiceRepositoryFactory: invoiceRepositoryFactory,
            subscriptionRepositoryFactory: subscriptionRepositoryFactory, logger: logger
        ) { try $0.suspend(reason: params.reason, now: now()) }
    }
}

/// `invoice.refunded` / `invoice.cancelled` / `invoice.unsubscribed` -> `Cancel("Payment <status>")`.
struct CancelSubscriptionUseCase: UseCase {
    struct Params: Sendable {
        let invoiceId: Invoice.Id
        let reason: String
    }

    let context: any UnitOfWorkContext
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository>
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        context: any UnitOfWorkContext,
        invoiceRepositoryFactory: @escaping RepositoryFactory<any InvoiceRepository>,
        subscriptionRepositoryFactory: @escaping RepositoryFactory<any SubscriptionRepository>,
        now: @escaping @Sendable () -> Date = { .now },
        logger: Logger
    ) {
        self.context = context
        self.invoiceRepositoryFactory = invoiceRepositoryFactory
        self.subscriptionRepositoryFactory = subscriptionRepositoryFactory
        self.now = now
        self.logger = logger
    }

    func execute(params: Params) async throws {
        try await SubscriptionStatusChange.apply(
            action: "cancel", invoiceId: params.invoiceId, context: context,
            invoiceRepositoryFactory: invoiceRepositoryFactory,
            subscriptionRepositoryFactory: subscriptionRepositoryFactory, logger: logger
        ) { try $0.cancel(reason: params.reason, now: now()) }
    }
}

/// Shared flow of suspend / cancel: load the invoice, find the order's subscription (a missing
/// one is a no-op, as in Node), apply the transition, persist when it changed. An invalid
/// transition (e.g. cancelling an `expired` subscription) is logged and leaves everything as it was.
enum SubscriptionStatusChange {
    static func apply(
        action: String,
        invoiceId: Invoice.Id,
        context: any UnitOfWorkContext,
        invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>,
        subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository>,
        logger: Logger,
        change: (Subscription) throws -> Bool
    ) async throws {
        let metadata: Logger.Metadata = ["invoiceId": .string(invoiceId.rawValue), "action": .string(action)]
        logger.info("Changing subscription status", metadata: metadata)

        guard let invoice = try await invoiceRepositoryFactory(context).fetch(byId: invoiceId) else {
            logger.warning("Invoice not found, subscription left as is", metadata: metadata)
            return
        }
        let repository = subscriptionRepositoryFactory(context)
        guard let subscription = try await repository.find(
            accountId: invoice.accountId, orderId: invoice.orderId.rawValue
        ) else {
            logger.info("No subscription for the order, nothing to \(action)", metadata: metadata)
            return
        }
        do {
            if try change(subscription) {
                try await repository.update(entity: subscription)
            }
        } catch let error as InvalidStatusTransitionError {
            logger.warning("Subscription transition refused, left as is", metadata: metadata.merging([
                "subscriptionId": .string(subscription.id.rawValue), "reason": .string("\(error)")
            ]) { $1 })
        }
    }
}
