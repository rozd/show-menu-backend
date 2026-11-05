import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("Order aggregate")
struct OrderTests {

    private let invoiceId = Invoice.Id(rawValue: "invoice-1")

    /// An order rehydrated in `status`, linked to `invoiceId`, with a clean event recorder.
    private func order(in status: OrderStatus) throws -> Order {
        let source = try PurchaseFixtures.makeOrder()
        return Order(
            id: source.id,
            accountId: source.accountId,
            customerId: source.customerId,
            lineItems: source.lineItems,
            discounts: [],
            shipment: source.shipment,
            customer: source.customer,
            status: status,
            invoiceId: invoiceId
        )
    }

    private func apply(_ target: OrderStatus, to order: Order) throws -> Bool {
        switch target {
        case .completed: try order.complete(invoiceId: invoiceId)
        case .failed: try order.fail(invoiceId: invoiceId)
        case .cancelled: try order.cancel(invoiceId: invoiceId)
        case .refunded: try order.refund()
        case .created: fatalError("no behavior method targets `created`")
        }
    }

    private static let validEdges: [(OrderStatus, OrderStatus, OrderEventKind)] = [
        (.created, .completed, .orderCompleted),
        (.created, .failed, .orderFailed),
        (.created, .cancelled, .orderCancelled),
        (.cancelled, .completed, .orderCompleted),
        (.cancelled, .failed, .orderFailed),
        (.completed, .refunded, .orderRefunded),
    ]

    @Test("create records the semantic order.created event and starts in `created` without an invoice")
    func create() throws {
        let order = try PurchaseFixtures.makeOrder()
        #expect(order.status == .created)
        #expect(order.invoiceId == nil)
        #expect(order.id.rawValue.hasPrefix("order-"))
        #expect(order.pullEvents().map(\.kind) == [.orderPlaced])
    }

    @Test("an order needs line items and an account")
    func createValidation() throws {
        #expect(throws: Order.Error.lineItemsRequired) {
            try Order.create(
                accountId: "a", customerId: .init(rawValue: "u"), lineItems: [],
                shipment: ShipmentInfo(), customer: CustomerInfo(name: "n")
            )
        }
        #expect(throws: Order.Error.accountRequired) {
            try Order.create(
                accountId: "", customerId: .init(rawValue: "u"), lineItems: [try PurchaseFixtures.product()],
                shipment: ShipmentInfo(), customer: CustomerInfo(name: "n")
            )
        }
    }

    @Test("every valid edge transitions and records exactly its semantic event", arguments: validEdges)
    func validTransition(edge: (OrderStatus, OrderStatus, OrderEventKind)) throws {
        let order = try order(in: edge.0)
        #expect(try apply(edge.1, to: order) == true)
        #expect(order.status == edge.1)
        #expect(order.pullEvents().map(\.kind) == [edge.2])
    }

    @Test("every edge outside the table throws and leaves the order untouched")
    func invalidTransitions() throws {
        let all = OrderStatus.allCases
        let valid = Set(Self.validEdges.map { "\($0.0)->\($0.1)" })
        var checked = 0
        for from in all {
            for to in all where to != .created && to != from && !valid.contains("\(from)->\(to)") {
                let order = try order(in: from)
                #expect(throws: InvalidStatusTransitionError.self, "\(from) -> \(to)") {
                    try apply(to, to: order)
                }
                #expect(order.status == from)
                #expect(order.pullEvents().isEmpty)
                checked += 1
            }
        }
        // 5 states x 3 non-`created` targets (excluding self) minus the 6 valid edges... sanity: not vacuous.
        #expect(checked >= 10)
    }

    @Test("representative invalid transitions")
    func representativeInvalid() throws {
        for (from, to) in [(OrderStatus.completed, OrderStatus.cancelled), (.failed, .completed), (.refunded, .completed), (.created, .refunded), (.cancelled, .refunded)] {
            let order = try order(in: from)
            #expect(throws: InvalidStatusTransitionError.self) { try apply(to, to: order) }
        }
    }

    @Test("a transition to nothing in the table targets `created`")
    func nothingTargetsCreated() {
        #expect(!Order.transitions.contains { $0.target == .created })
    }

    @Test("repeating the current status is an idempotent no-op")
    func idempotent() throws {
        let order = try order(in: .created)
        #expect(try order.complete(invoiceId: invoiceId) == true)
        _ = order.pullEvents()
        #expect(try order.complete(invoiceId: invoiceId) == false)
        #expect(order.pullEvents().isEmpty)
    }

    @Test("an invoice that is not the order's own is rejected")
    func invoiceMismatch() throws {
        let order = try order(in: .created)
        #expect(throws: InvoiceOrderMismatchError.self) { try order.complete(invoiceId: .init(rawValue: "invoice-other")) }
        #expect(throws: InvoiceOrderMismatchError.self) { try order.cancel(invoiceId: .init(rawValue: "invoice-other")) }
        #expect(order.status == .created)
    }

    @Test("createInvoice links a pending invoice copying the lines; a second call throws")
    func createInvoice() throws {
        let order = try PurchaseFixtures.makeOrder()
        let invoice = try order.createInvoice()
        #expect(order.invoiceId == invoice.id)
        #expect(invoice.id.rawValue.hasPrefix("invoice-"))
        #expect(invoice.orderId == order.id)
        #expect(invoice.status == .pending)
        #expect(invoice.lineItems == order.lineItems)
        #expect(invoice.accountId == order.accountId && invoice.customerId == order.customerId)
        #expect(invoice.dueDate == nil && invoice.transactionId == nil)
        #expect(throws: OrderInvoiceAlreadyCreatedError.self) { try order.createInvoice() }
    }

    @Test("order exposes amount, currency and payment action for checkout")
    func checkoutAccessors() throws {
        let plan = try PurchaseFixtures.makeOrder()
        #expect(plan.amount == 2900)
        #expect(plan.currency?.name == "USD")
        #expect(plan.paymentAction == .subscribe)
        #expect(plan.subscriptionDuration == .monthly)

        let oneOff = try PurchaseFixtures.makeOrder(lines: [try PurchaseFixtures.product(duration: nil, amount: 10.5, quantity: 2)])
        #expect(oneOff.amount == 21)
        #expect(oneOff.paymentAction == .pay)
        #expect(oneOff.subscriptionDuration == nil)
    }

    @Test("line validation")
    func lineValidation() throws {
        let price = try Price(currency: Currency(name: "USD"), amount: 1)
        let name = try LocalizedString(["en": "n"])
        #expect(throws: OrderProduct.Error.invalidQuantity) {
            try OrderProduct(sku: "s", productId: "p", productName: name, productPrice: price, quantity: 0)
        }
        #expect(throws: OrderProduct.Error.skuRequired) {
            try OrderProduct(sku: "", productId: "p", productName: name, productPrice: price, quantity: 1)
        }
        #expect(throws: OrderProduct.Error.productIdRequired) {
            try OrderProduct(sku: "s", productId: "", productName: name, productPrice: price, quantity: 1)
        }
    }
}
