import Foundation
import Logging

/// Follow-on work on the Subscription aggregate for the invoice events of the LiqPay callback
/// (S13). Subscribed to every `InvoiceEvent` kind and routes on `event.kind`; each action runs
/// in **its own unit of work** (another aggregate than the one that raised the event), after the
/// callback transaction has committed.
///
/// | invoice event          | subscription                                  |
/// |------------------------|-----------------------------------------------|
/// | `invoice.paid`         | activate (create, or extend if it exists)     |
/// | `invoice.renewed`      | extend by one more period                     |
/// | `invoice.failed`       | suspend("Payment failed")                     |
/// | `invoice.charge_failed`| suspend("Payment failed") (recurring charge)  |
/// | `invoice.refunded`     | cancel("Payment refunded")                    |
/// | `invoice.cancelled`    | cancel("Payment cancelled")                   |
/// | `invoice.unsubscribed` | cancel("Payment unsubscribed")                |
///
/// Events are kind-only; the handler loads the invoice by `event.aggregateId`. Errors are caught
/// and logged (the dispatcher contract); every action is idempotent, so a re-delivery is harmless.
struct SubscriptionInvoiceEventHandler: DomainEventHandler {
    typealias Event = InvoiceEvent

    let unitOfWork: any UnitOfWork
    let activateUseCaseFactory: UseCaseFactory<ActivateSubscriptionUseCase>
    let suspendUseCaseFactory: UseCaseFactory<SuspendSubscriptionUseCase>
    let cancelUseCaseFactory: UseCaseFactory<CancelSubscriptionUseCase>
    let logger: Logger

    func handle(event: InvoiceEvent) async {
        let invoiceId = event.aggregateId
        let metadata: Logger.Metadata = [
            "invoiceId": .string(invoiceId.rawValue),
            "kind": .string(event.kind.rawValue),
            "eventId": .string(event.id.uuidString),
        ]

        do {
            switch event.kind {
            case .invoicePaid:
                try await activate(invoiceId, .paid)
            case .invoiceRenewed:
                try await activate(invoiceId, .renewed)
            case .invoiceFailed, .invoiceChargeFailed:
                try await suspend(invoiceId, reason: "Payment failed")
            case .invoiceRefunded:
                try await cancel(invoiceId, reason: "Payment refunded")
            case .invoiceCancelled:
                try await cancel(invoiceId, reason: "Payment cancelled")
            case .invoiceUnsubscribed:
                try await cancel(invoiceId, reason: "Payment unsubscribed")
            case .invoiceCreated, .invoiceUpdated, .invoiceDeleted:
                return
            }
            logger.info("Handled InvoiceEvent for the subscription", metadata: metadata)
        } catch {
            logger.error("Failed to handle InvoiceEvent for the subscription", metadata: metadata.merging([
                "error": .string("\(error)")
            ]) { $1 })
        }
    }

    private func activate(_ invoiceId: Invoice.Id, _ trigger: ActivateSubscriptionUseCase.Trigger) async throws {
        let factory = activateUseCaseFactory
        try await unitOfWork.execute { ctx in
            try await factory(ctx).execute(params: .init(invoiceId: invoiceId, trigger: trigger))
        }
    }

    private func suspend(_ invoiceId: Invoice.Id, reason: String) async throws {
        let factory = suspendUseCaseFactory
        try await unitOfWork.execute { ctx in
            try await factory(ctx).execute(params: .init(invoiceId: invoiceId, reason: reason))
        }
    }

    private func cancel(_ invoiceId: Invoice.Id, reason: String) async throws {
        let factory = cancelUseCaseFactory
        try await unitOfWork.execute { ctx in
            try await factory(ctx).execute(params: .init(invoiceId: invoiceId, reason: reason))
        }
    }
}
