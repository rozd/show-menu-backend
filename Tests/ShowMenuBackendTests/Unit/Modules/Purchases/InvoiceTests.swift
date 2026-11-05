import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("Invoice aggregate")
struct InvoiceTests {

    private func invoice(in status: InvoiceStatus) throws -> Invoice {
        let source = try PurchaseFixtures.makeOrder().createInvoice()
        return Invoice(
            id: source.id, orderId: source.orderId, accountId: source.accountId, customerId: source.customerId,
            transactionId: nil, status: status, lineItems: source.lineItems, discounts: [],
            orderDate: source.orderDate, issueDate: source.issueDate, dueDate: nil,
            customer: source.customer, shipment: source.shipment
        )
    }

    private func apply(_ target: InvoiceStatus, to invoice: Invoice) throws -> Bool {
        switch target {
        case .paid: try invoice.pay()
        case .failed: try invoice.fail()
        case .cancelled: try invoice.cancel()
        case .refunded: try invoice.refund()
        case .pending: fatalError("no behavior method targets `pending`")
        }
    }

    private static let validEdges: [(InvoiceStatus, InvoiceStatus, InvoiceEventKind)] = [
        (.pending, .paid, .invoicePaid),
        (.pending, .cancelled, .invoiceCancelled),
        (.pending, .failed, .invoiceFailed),
        (.paid, .refunded, .invoiceRefunded),
    ]

    @Test("every valid edge transitions and records exactly its semantic event", arguments: validEdges)
    func validTransition(edge: (InvoiceStatus, InvoiceStatus, InvoiceEventKind)) throws {
        let invoice = try invoice(in: edge.0)
        #expect(try apply(edge.1, to: invoice) == true)
        #expect(invoice.status == edge.1)
        #expect(invoice.pullEvents().map(\.kind) == [edge.2])
    }

    @Test("every edge outside the table throws and leaves the invoice untouched")
    func invalidTransitions() throws {
        let valid = Set(Self.validEdges.map { "\($0.0)->\($0.1)" })
        var checked = 0
        for from in InvoiceStatus.allCases {
            for to in InvoiceStatus.allCases where to != .pending && to != from && !valid.contains("\(from)->\(to)") {
                let invoice = try invoice(in: from)
                #expect(throws: InvalidStatusTransitionError.self, "\(from) -> \(to)") {
                    try apply(to, to: invoice)
                }
                #expect(invoice.status == from)
                #expect(invoice.pullEvents().isEmpty)
                checked += 1
            }
        }
        #expect(checked >= 8)
    }

    @Test("paying records the transaction id; repeating is a no-op that keeps it")
    func payIdempotent() throws {
        let invoice = try invoice(in: .pending)
        #expect(try invoice.pay(transactionId: "tx-1") == true)
        #expect(invoice.transactionId == "tx-1")
        _ = invoice.pullEvents()
        #expect(try invoice.pay(transactionId: "tx-2") == false)
        #expect(invoice.transactionId == "tx-1")
        #expect(invoice.pullEvents().isEmpty)
    }

    @Test("amount, currency, payment action and description for checkout")
    func accessors() throws {
        let invoice = try invoice(in: .pending)
        #expect(invoice.amount == 2900)
        #expect(invoice.currency?.name == "USD")
        #expect(invoice.paymentAction == .subscribe)
        #expect(invoice.subscriptionDuration == .monthly)
        #expect(invoice.description == "Order #\(invoice.orderId.rawValue)")
    }

    @Test("feeds CheckoutRequest: order_id = invoice id, description from the order id, subscribe + duration")
    func checkoutRequest() throws {
        let invoice = try invoice(in: .pending)
        let request = try invoice.checkoutRequest(resultURL: "https://example.com/done")
        #expect(request.orderId == invoice.id.rawValue)
        #expect(request.amount == 2900)
        #expect(request.currency == "USD")
        #expect(request.description == "Order #\(invoice.orderId.rawValue)")
        #expect(request.subscription == .monthly)
        #expect(request.resultURL == "https://example.com/done")
    }

    @Test("a one-off line is `pay` with no subscription")
    func oneOff() throws {
        let order = try PurchaseFixtures.makeOrder(lines: [try PurchaseFixtures.product(duration: nil, amount: 5, quantity: 3)])
        let invoice = try order.createInvoice()
        #expect(invoice.paymentAction == .pay)
        #expect(invoice.amount == 15)
        #expect(try invoice.checkoutRequest().subscription == nil)
    }
}
