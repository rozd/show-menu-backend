import Foundation

/// The invoice of an order (`invoices/{id}`).
///
/// FSM (Node `Invoice.fsm`): `pending → paid | cancelled | failed`, `paid → refunded`.
/// Invalid transitions throw ``InvalidStatusTransitionError`` (Node logged and swallowed
/// them); a transition to the current status is an idempotent no-op returning `false`.
final class Invoice: AggregateRoot, @unchecked Sendable {
    typealias Event = InvoiceEvent

    let id: Invoice.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer.
    var version: Version = .none

    let orderId: Order.Id
    let accountId: String
    let customerId: User.Id
    private(set) var transactionId: String?
    private(set) var status: InvoiceStatus
    let lineItems: [OrderProduct]
    let discounts: [OrderDiscount]
    let orderDate: Date
    let issueDate: Date
    let dueDate: Date?
    let customer: CustomerInfo
    let shipment: ShipmentInfo
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Rehydration initializer (no validation, no events): used by the mapper.
    init(
        id: Invoice.Id,
        orderId: Order.Id,
        accountId: String,
        customerId: User.Id,
        transactionId: String?,
        status: InvoiceStatus,
        lineItems: [OrderProduct],
        discounts: [OrderDiscount],
        orderDate: Date,
        issueDate: Date,
        dueDate: Date?,
        customer: CustomerInfo,
        shipment: ShipmentInfo,
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.orderId = orderId
        self.accountId = accountId
        self.customerId = customerId
        self.transactionId = transactionId
        self.status = status
        self.lineItems = lineItems
        self.discounts = discounts
        self.orderDate = orderDate
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.customer = customer
        self.shipment = shipment
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// A `pending` invoice copying the order's lines (Node `Invoice.create`). Prefer
    /// ``Order/createInvoice(now:)``, which also links it.
    static func create(order: Order, now: Date = .now) -> Invoice {
        Invoice(
            id: .generate(),
            orderId: order.id,
            accountId: order.accountId,
            customerId: order.customerId,
            transactionId: nil,
            status: .pending,
            lineItems: order.lineItems,
            discounts: order.discounts,
            orderDate: order.createdAt,
            issueDate: now,
            dueDate: nil,
            customer: order.customer,
            shipment: order.shipment,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: Derived (what checkout needs)

    var amount: Double { lineItems.totalAmount }
    var currency: Currency? { lineItems.currency }
    var paymentAction: PaymentAction { lineItems.paymentAction }
    var subscriptionDuration: SubscriptionDuration? { lineItems.subscriptionDuration }
    /// LiqPay `description` (roadmap bug 5): `Order #<orderId>`.
    var description: String { "Order #\(orderId.rawValue)" }

    /// The request the payment gateway needs to open a hosted page for this invoice.
    func checkoutRequest(resultURL: String? = nil, language: String? = nil) throws -> CheckoutRequest {
        try CheckoutRequest(
            invoiceId: id.rawValue,
            orderId: orderId.rawValue,
            lines: lineItems.checkoutLines,
            resultURL: resultURL,
            language: language
        )
    }

    // MARK: Transitions

    /// `pending → paid`; records `transactionId` when given.
    @discardableResult
    func pay(transactionId: String? = nil, now: Date = .now) throws -> Bool {
        let changed = try move(to: .paid, event: .invoicePaid, now: now)
        if changed, let transactionId { self.transactionId = transactionId }
        return changed
    }

    @discardableResult
    func fail(now: Date = .now) throws -> Bool {
        try move(to: .failed, event: .invoiceFailed, now: now)
    }

    @discardableResult
    func cancel(now: Date = .now) throws -> Bool {
        try move(to: .cancelled, event: .invoiceCancelled, now: now)
    }

    @discardableResult
    func refund(now: Date = .now) throws -> Bool {
        try move(to: .refunded, event: .invoiceRefunded, now: now)
    }

    private func move(to target: InvoiceStatus, event: InvoiceEventKind, now: Date) throws -> Bool {
        guard status != target else { return false }
        var fsm = FiniteStateMachine(initial: status, transitions: Invoice.transitions)
        do {
            try fsm.transition(to: target)
        } catch {
            throw InvalidStatusTransitionError(
                aggregate: "invoice", id: id.rawValue, from: status.rawValue, to: target.rawValue
            )
        }
        status = target
        updatedAt = now
        record(event: .semantic(event, aggregateId: id, occurredAt: now))
        return true
    }

    static let transitions: [StateTransition<InvoiceStatus>] = [
        .init(source: .pending, target: .paid),
        .init(source: .pending, target: .cancelled),
        .init(source: .pending, target: .failed),
        .init(source: .paid, target: .refunded),
    ]
}

extension Invoice {
    struct Id: PrefixedEntityId {
        static let prefix = "invoice-"

        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    enum Error: ValidationError, LocalizedError, Equatable {
        case lineItemsRequired

        var errorDescription: String? { "Line items are required" }
    }
}

/// Node's `PaymentStatus` (named `InvoiceStatus` here: `PaymentStatus` is the gateway's
/// provider-status projection). Raw values are the stored strings.
enum InvoiceStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending, paid, cancelled, refunded, failed
}
