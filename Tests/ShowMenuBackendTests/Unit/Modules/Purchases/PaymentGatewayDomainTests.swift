import Foundation
import Testing
@testable import ShowMenuBackend

@Suite("Purchases payment gateway port")
struct PaymentGatewayDomainTests {

    @Test("builder sums amount x quantity, takes the first line's currency, names the order")
    func builderSums() throws {
        let request = try CheckoutRequest(
            invoiceId: "inv-9", orderId: "ord-3",
            lines: [
                CheckoutLine(amount: 10, quantity: 2, currencyName: "UAH", duration: nil),
                CheckoutLine(amount: 0.5, quantity: 3, currencyName: "USD", duration: nil),
            ],
            resultURL: "https://example.test/done"
        )
        #expect(request.orderId == "inv-9")
        #expect(request.amount == 21.5)
        #expect(request.currency == "UAH")
        #expect(request.description == "Order #ord-3")
        #expect(request.subscription == nil)
        #expect(request.resultURL == "https://example.test/done")
    }

    @Test("first line's duration makes it a subscription")
    func builderSubscription() throws {
        let request = try CheckoutRequest(
            invoiceId: "i", orderId: "o",
            lines: [CheckoutLine(amount: 5, quantity: 1, currencyName: "UAH", duration: .monthly)]
        )
        #expect(request.subscription == .monthly)
    }

    @Test("empty lines are a validation error")
    func builderEmpty() {
        #expect(throws: CheckoutRequestError.noLines) {
            _ = try CheckoutRequest(invoiceId: "i", orderId: "o", lines: [])
        }
    }

    @Test("gateway errors map to their HTTP status hints through the error envelope")
    func errorStatuses() {
        let table: [(PaymentGatewayError, UInt)] = [
            (.notConfigured, 503), (.invalidSignature, 401), (.invalidPayload("x"), 400),
            (.transport("x"), 502), (.unexpectedResponse("x"), 502),
        ]
        for (error, status) in table {
            #expect(error.httpStatusHint.code == status)
            #expect(HTTPErrorMapping.map(error).status.code == status)
        }
    }
}
