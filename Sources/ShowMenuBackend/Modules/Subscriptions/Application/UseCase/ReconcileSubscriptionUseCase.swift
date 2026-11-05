import Foundation
import Logging

/// Reconcile pass, one paid invoice in its own unit of work: if the invoice's order has **no**
/// subscription document yet, run the S14 activation for it; otherwise do nothing.
///
/// Why gate on existence instead of just re-running ``ActivateSubscriptionUseCase``: that use case
/// extends an existing subscription whenever the invoice's payment reference differs from the
/// stored `lastPaymentRef`, and subscriptions created by the Node functions have none, so a blind
/// re-run would grant every legacy subscription a free period. Here an existing subscription
/// (derived id, or legacy `orderId` lookup) is never touched.
///
/// Returns `true` when a subscription was created.
struct ReconcileSubscriptionUseCase: UseCase {
    struct Params: Sendable {
        let invoiceId: Invoice.Id
    }

    let context: any UnitOfWorkContext
    let invoiceRepositoryFactory: RepositoryFactory<any InvoiceRepository>
    let subscriptionRepositoryFactory: RepositoryFactory<any SubscriptionRepository>
    let activate: ActivateSubscriptionUseCase
    let logger: Logger

    func execute(params: Params) async throws -> Bool {
        guard let invoice = try await invoiceRepositoryFactory(context).fetch(byId: params.invoiceId),
              invoice.status == .paid,
              invoice.lineItems.contains(where: { $0.duration != nil })
        else {
            return false
        }
        let existing = try await subscriptionRepositoryFactory(context).find(
            accountId: invoice.accountId, orderId: invoice.orderId.rawValue
        )
        guard existing == nil else { return false }

        logger.warning("Paid invoice without a subscription, activating", metadata: [
            "invoiceId": .string(invoice.id.rawValue), "orderId": .string(invoice.orderId.rawValue)
        ])
        return try await activate.execute(params: .init(invoiceId: invoice.id, trigger: .paid)) == .created
    }
}
