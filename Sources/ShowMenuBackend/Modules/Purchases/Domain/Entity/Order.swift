import Foundation

/// A purchase order (`accounts/{accountId}/orders/{id}`).
///
/// FSM (Node `Order.fsm`): `created → completed | failed | cancelled`,
/// `cancelled → completed | failed`, `completed → refunded`. Anything else throws
/// ``InvalidStatusTransitionError`` (Node swallowed it). A transition to the **current**
/// status is an idempotent no-op (returns `false`, no event), so a redelivered callback is harmless.
/// Semantic events are raised here, at the transition; lifecycle events come from the Repository.
final class Order: AggregateRoot, @unchecked Sendable {
    typealias Event = OrderEvent

    let id: Order.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer.
    var version: Version = .none

    let accountId: String
    let customerId: User.Id
    let lineItems: [OrderProduct]
    let discounts: [OrderDiscount]
    let shipment: ShipmentInfo
    let customer: CustomerInfo
    /// Node's `userData` (stored as `userInfo`); always `null` in practice.
    let userData: [String: String]?
    private(set) var status: OrderStatus
    private(set) var invoiceId: Invoice.Id?
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Rehydration initializer (no validation, no events): used by the mapper.
    init(
        id: Order.Id,
        accountId: String,
        customerId: User.Id,
        lineItems: [OrderProduct],
        discounts: [OrderDiscount],
        shipment: ShipmentInfo,
        customer: CustomerInfo,
        userData: [String: String]? = nil,
        status: OrderStatus,
        invoiceId: Invoice.Id?,
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.customerId = customerId
        self.lineItems = lineItems
        self.discounts = discounts
        self.shipment = shipment
        self.customer = customer
        self.userData = userData
        self.status = status
        self.invoiceId = invoiceId
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Creates a `created` order and records the semantic `order.created` event.
    static func create(
        accountId: String,
        customerId: User.Id,
        lineItems: [OrderProduct],
        discounts: [OrderDiscount] = [],
        shipment: ShipmentInfo,
        customer: CustomerInfo,
        userData: [String: String]? = nil,
        now: Date = .now
    ) throws -> Order {
        guard !accountId.isEmpty else { throw Error.accountRequired }
        guard !lineItems.isEmpty else { throw Error.lineItemsRequired }
        let order = Order(
            id: .generate(),
            accountId: accountId,
            customerId: customerId,
            lineItems: lineItems,
            discounts: discounts,
            shipment: shipment,
            customer: customer,
            userData: userData,
            status: .created,
            invoiceId: nil,
            createdAt: now,
            updatedAt: now
        )
        order.record(event: .semantic(.orderPlaced, aggregateId: order.id, occurredAt: now))
        return order
    }

    // MARK: Derived (what checkout needs)

    var amount: Double { lineItems.totalAmount }
    var currency: Currency? { lineItems.currency }
    var paymentAction: PaymentAction { lineItems.paymentAction }
    var subscriptionDuration: SubscriptionDuration? { lineItems.subscriptionDuration }

    // MARK: Invoice

    /// Creates the order's invoice and links it (Node `Order.createInvoice`).
    func createInvoice(now: Date = .now) throws -> Invoice {
        guard invoiceId == nil else { throw OrderInvoiceAlreadyCreatedError(orderId: id) }
        let invoice = Invoice.create(order: self, now: now)
        invoiceId = invoice.id
        updatedAt = now
        return invoice
    }

    // MARK: Transitions

    /// Returns `false` (no change, no event) when already completed.
    @discardableResult
    func complete(invoiceId: Invoice.Id, now: Date = .now) throws -> Bool {
        try move(to: .completed, event: .orderCompleted, invoiceId: invoiceId, now: now)
    }

    @discardableResult
    func fail(invoiceId: Invoice.Id, now: Date = .now) throws -> Bool {
        try move(to: .failed, event: .orderFailed, invoiceId: invoiceId, now: now)
    }

    @discardableResult
    func cancel(invoiceId: Invoice.Id, now: Date = .now) throws -> Bool {
        try move(to: .cancelled, event: .orderCancelled, invoiceId: invoiceId, now: now)
    }

    /// `completed → refunded` (Node's `refund()` threw "Not implemented" although its FSM had the edge).
    @discardableResult
    func refund(now: Date = .now) throws -> Bool {
        try move(to: .refunded, event: .orderRefunded, invoiceId: nil, now: now)
    }

    private func move(
        to target: OrderStatus,
        event: OrderEventKind,
        invoiceId: Invoice.Id?,
        now: Date
    ) throws -> Bool {
        if let invoiceId, invoiceId != self.invoiceId {
            throw InvoiceOrderMismatchError(orderId: id, invoiceId: invoiceId)
        }
        guard status != target else { return false }
        var fsm = FiniteStateMachine(initial: status, transitions: Order.transitions)
        do {
            try fsm.transition(to: target)
        } catch {
            throw InvalidStatusTransitionError(
                aggregate: "order", id: id.rawValue, from: status.rawValue, to: target.rawValue
            )
        }
        status = target
        updatedAt = now
        record(event: .semantic(event, aggregateId: id, occurredAt: now))
        return true
    }

    static let transitions: [StateTransition<OrderStatus>] = [
        .init(source: .created, target: .completed),
        .init(source: .created, target: .failed),
        .init(source: .created, target: .cancelled),
        .init(source: .cancelled, target: .completed),
        .init(source: .cancelled, target: .failed),
        .init(source: .completed, target: .refunded),
    ]
}

extension Order {
    struct Id: PrefixedEntityId {
        static let prefix = "order-"

        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    enum Error: ValidationError, LocalizedError, Equatable {
        case accountRequired
        case lineItemsRequired

        var errorDescription: String? {
            switch self {
            case .accountRequired: "Account ID is required"
            case .lineItemsRequired: "An order must have at least one product"
            }
        }
    }
}

/// Node's `OrderStatus` (raw values are the stored strings).
enum OrderStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case created, cancelled, completed, refunded, failed
}
