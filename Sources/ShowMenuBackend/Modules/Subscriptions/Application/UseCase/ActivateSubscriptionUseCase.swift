import Foundation
import Logging

/// Applies one payment to the subscription of the invoice's order: the follow-on work of
/// `invoice.paid` (first payment) and `invoice.renewed` (a further recurring payment).
///
/// * No subscription yet -> a new `active` one (deterministic id from the order, `create`
///   precondition) valid for one period from now. This also covers a renewal whose first
///   activation was lost (see the reliability note in roadmap §7 S14).
/// * Subscription exists -> ``Subscription/extend(by:paymentRef:now:)``: one period counted from
///   `max(now, expiresAt)`, reactivating a `suspended`/`expired` one.
///
/// Idempotent per payment: the payment identity (`invoice.transactionId`, else
/// `<invoiceId>:<trigger>`) is stored on the subscription as `lastPaymentRef`, and an event
/// re-run for the same payment changes nothing. A concurrent duplicate activation loses the
/// `create` precondition at commit, is retried by the transaction runner, finds the winner's
/// document and then hits the same marker.
///
/// Reads first (invoice, subscription), then the single write. No plan lookup: the plan id and
/// period come from the invoice's plan line (Node also read the plan only to take its id).
struct ActivateSubscriptionUseCase: UseCase {
    enum Trigger: String, Sendable {
        case paid, renewed
    }

    struct Params: Sendable {
        let invoiceId: Invoice.Id
        let trigger: Trigger
    }

    /// What the use case did (the event handler ignores it; the reconcile pass counts `created`).
    enum Outcome: Sendable, Equatable {
        /// A new subscription document was inserted.
        case created
        /// An existing subscription was extended / reactivated.
        case extended
        /// Nothing was written (payment already applied, invoice not paid, no plan line, ...).
        case skipped
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

    @discardableResult
    func execute(params: Params) async throws -> Outcome {
        let metadata: Logger.Metadata = [
            "invoiceId": .string(params.invoiceId.rawValue), "trigger": .string(params.trigger.rawValue)
        ]
        logger.info("Executing ActivateSubscriptionUseCase", metadata: metadata)

        guard let invoice = try await invoiceRepositoryFactory(context).fetch(byId: params.invoiceId) else {
            logger.warning("Invoice not found, no subscription to activate", metadata: metadata)
            return .skipped
        }
        // The event is dispatched after commit: skip if the invoice has moved on (e.g. refunded).
        guard invoice.status == .paid else {
            logger.warning("Invoice is not paid any more, subscription not activated", metadata: metadata.merging([
                "status": .string(invoice.status.rawValue)
            ]) { $1 })
            return .skipped
        }
        guard let line = invoice.lineItems.first(where: { $0.duration != nil }), let duration = line.duration else {
            logger.error("Invoice has no plan line, subscription not activated", metadata: metadata)
            return .skipped
        }

        let paymentRef = invoice.transactionId ?? "\(invoice.id.rawValue):\(params.trigger.rawValue)"
        let repository = subscriptionRepositoryFactory(context)
        let moment = now()

        guard let subscription = try await repository.find(accountId: invoice.accountId, orderId: invoice.orderId.rawValue) else {
            try await repository.insert(entity: Subscription.activate(
                accountId: invoice.accountId, orderId: invoice.orderId.rawValue, planId: line.productId,
                duration: duration, paymentRef: paymentRef, now: moment
            ))
            return .created
        }

        do {
            if try subscription.extend(by: duration, paymentRef: paymentRef, now: moment) {
                try await repository.update(entity: subscription)
                return .extended
            }
        } catch let error as InvalidStatusTransitionError {
            // A cancelled subscription is not reactivated by a late payment event; nothing was mutated.
            logger.error("Subscription cannot be extended", metadata: metadata.merging([
                "subscriptionId": .string(subscription.id.rawValue), "reason": .string("\(error)")
            ]) { $1 })
        }
        return .skipped
    }
}
