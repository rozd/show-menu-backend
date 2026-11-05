import Foundation
import Testing
import FirestoreAPI
@testable import ShowMenuBackend

/// Contract tests against the Firestore documents Node and the LiqPay extension write.
@Suite("Purchases mappers (Node document shapes)")
struct PurchaseMapperTests {
    typealias F = PurchaseFixtures

    private func isInteger(_ value: Any?) -> Bool { value is Int || value is Int64 || value is Int32 }

    // MARK: Order

    @Test("decodes a Node order document")
    func decodeOrder() throws {
        let model = try FirestoreDecoder().decode(OrderModel.self, from: F.orderDocument())
        let order = try OrderMapper().toEntity(model: model)
        #expect(order.id.rawValue == F.orderId)
        #expect(order.accountId == F.accountId && order.customerId.rawValue == F.customerId)
        #expect(order.status == .created)
        #expect(order.invoiceId?.rawValue == F.invoiceId)
        #expect(order.version == .none)
        #expect(order.userData == nil)
        #expect(order.customer == CustomerInfo(name: "Max", email: "max@example.com"))
        #expect(order.shipment == ShipmentInfo(method: .electronic, address: "max@example.com"))
        let line = try #require(order.lineItems.first)
        #expect(line.duration == .monthly)
        #expect(line.productPrice.amount == 2900)
        #expect(line.productPrice.currency.base == 100)
        #expect(line.productName["uk"] == "Про")
        #expect(order.createdAt.timeIntervalSince1970 == 1_767_225_600.123)
        #expect(order.paymentAction == .subscribe)
    }

    @Test("re-encoding a Node order document reproduces its keys and value kinds")
    func encodeOrderMatchesNode() throws {
        let node = F.orderDocument()
        let model = try FirestoreDecoder().decode(OrderModel.self, from: node)
        let entity = try OrderMapper().toEntity(model: model)
        let encoded = try FirestoreEncoder().encode(OrderMapper().toModel(entity: entity))

        // `version` is additive and omitted until the first versioned write.
        #expect(Set(encoded.keys) == Set(node.keys))
        #expect((encoded["createdAt"] as? Timestamp) == F.created)
        #expect((encoded["updatedAt"] as? Timestamp) == F.updated)
        #expect(encoded["userInfo"] is NSNull)
        #expect(encoded["invoiceId"] as? String == F.invoiceId)
        #expect(encoded["status"] as? String == "created")
        #expect((encoded["discounts"] as? [Any])?.isEmpty == true)

        let shipment = try #require(encoded["shipment"] as? [String: Any])
        #expect(Set(shipment.keys) == ["method", "address"])
        #expect(shipment["method"] as? String == "electronic")
        let customer = try #require(encoded["customer"] as? [String: Any])
        #expect(Set(customer.keys) == ["name", "email", "phone", "address"])
        #expect(customer["phone"] is NSNull && customer["address"] is NSNull)

        let line = try #require((encoded["lineItems"] as? [[String: Any]])?.first)
        #expect(Set(line.keys) == ["sku", "productId", "productName", "productPrice", "quantity", "duration"])
        #expect(line["duration"] as? String == "monthly")
        #expect(isInteger(line["quantity"]), "quantity must be integerValue")
        let price = try #require(line["productPrice"] as? [String: Any])
        #expect(isInteger(price["amount"]), "whole amount must be integerValue")
        let currency = try #require(price["currency"] as? [String: Any])
        #expect(Set(currency.keys) == ["symbol", "name", "base", "digits"])
        #expect(isInteger(currency["base"]) && isInteger(currency["digits"]))
    }

    @Test("order without an invoice writes explicit null; a non-plan line has no duration key")
    func orderNulls() throws {
        let order = try PurchaseFixtures.makeOrder(lines: [try F.product(duration: nil, amount: 10.5)])
        let encoded = try FirestoreEncoder().encode(OrderMapper().toModel(entity: order))
        #expect(encoded["invoiceId"] is NSNull)
        #expect(encoded["userInfo"] is NSNull)
        let line = try #require((encoded["lineItems"] as? [[String: Any]])?.first)
        #expect(line["duration"] == nil && line["productDetails"] == nil)
        let price = try #require(line["productPrice"] as? [String: Any])
        #expect(price["amount"] is Double, "a fractional amount stays a double")
    }

    @Test("legacy order documents missing optional fields decode")
    func legacyOrder() throws {
        var doc = F.orderDocument()
        doc.removeValue(forKey: "userInfo")
        doc.removeValue(forKey: "invoiceId")
        doc.removeValue(forKey: "discounts")
        doc["customer"] = ["name": "Max"]
        doc["shipment"] = ["method": "electronic"]
        doc["lineItems"] = [F.planLine(duration: false)]
        let order = try OrderMapper().toEntity(model: FirestoreDecoder().decode(OrderModel.self, from: doc))
        #expect(order.invoiceId == nil && order.discounts.isEmpty)
        #expect(order.customer.email == nil && order.shipment.address == nil)
        #expect(order.lineItems.first?.duration == nil)
        #expect(order.paymentAction == .pay)
    }

    @Test("an unknown order status is a decoding error, not a silent default")
    func unknownOrderStatus() {
        var doc = F.orderDocument()
        doc["status"] = "exploded"
        #expect(throws: (any Error).self) { try FirestoreDecoder().decode(OrderModel.self, from: doc) }
    }

    @Test("order round trip preserves everything, including the version token")
    func orderRoundTrip() throws {
        let order = try PurchaseFixtures.makeOrder()
        _ = try order.createInvoice(now: Date(timeIntervalSince1970: 1_767_225_700))
        order.version = Version(3)
        let encoded = try FirestoreEncoder().encode(OrderMapper().toModel(entity: order))
        #expect(isInteger(encoded["version"]))
        let restored = try OrderMapper().toEntity(model: FirestoreDecoder().decode(OrderModel.self, from: encoded))
        #expect(restored.id == order.id)
        #expect(restored.lineItems == order.lineItems)
        #expect(restored.invoiceId == order.invoiceId)
        #expect(restored.version == Version(3))
        #expect(abs(restored.createdAt.timeIntervalSince(order.createdAt)) < 0.001)
    }

    // MARK: Invoice

    @Test("decodes a Node invoice document")
    func decodeInvoice() throws {
        let model = try FirestoreDecoder().decode(InvoiceModel.self, from: F.invoiceDocument())
        let invoice = try InvoiceMapper().toEntity(model: model)
        #expect(invoice.id.rawValue == F.invoiceId && invoice.orderId.rawValue == F.orderId)
        #expect(invoice.status == .pending)
        #expect(invoice.transactionId == nil && invoice.dueDate == nil)
        #expect(invoice.shipment == ShipmentInfo(method: .electronic, address: "max@example.com"))
        #expect(invoice.amount == 2900 && invoice.currency?.name == "USD")
        #expect(invoice.paymentAction == .subscribe)
        #expect(invoice.issueDate.timeIntervalSince1970 == 1_767_225_600.123)
    }

    @Test("re-encoding a Node invoice document reproduces its keys and value kinds")
    func encodeInvoiceMatchesNode() throws {
        let node = F.invoiceDocument()
        let entity = try InvoiceMapper().toEntity(model: FirestoreDecoder().decode(InvoiceModel.self, from: node))
        let encoded = try FirestoreEncoder().encode(InvoiceMapper().toModel(entity: entity))
        #expect(Set(encoded.keys) == Set(node.keys))
        #expect(encoded["transactionId"] is NSNull)
        #expect(encoded["dueDate"] is NSNull)
        #expect(encoded["shipmentMethod"] as? String == "electronic")
        #expect(encoded["shipmentAddress"] as? String == "max@example.com")
        #expect(encoded["status"] as? String == "pending")
        #expect((encoded["issueDate"] as? Timestamp) == F.created)
        #expect((encoded["orderDate"] as? Timestamp) == F.created)
        let line = try #require((encoded["lineItems"] as? [[String: Any]])?.first)
        #expect(isInteger(line["quantity"]))
        #expect(isInteger((line["productPrice"] as? [String: Any])?["amount"]))
    }

    @Test("legacy invoice documents missing optional fields decode")
    func legacyInvoice() throws {
        var doc = F.invoiceDocument()
        for key in ["transactionId", "dueDate", "shipmentAddress", "discounts"] { doc.removeValue(forKey: key) }
        let invoice = try InvoiceMapper().toEntity(model: FirestoreDecoder().decode(InvoiceModel.self, from: doc))
        #expect(invoice.transactionId == nil && invoice.dueDate == nil && invoice.shipment.address == nil)
        #expect(invoice.discounts.isEmpty)
    }

    @Test("a paid invoice with a due date round-trips")
    func invoiceRoundTrip() throws {
        let invoice = try PurchaseFixtures.makeOrder().createInvoice()
        try invoice.pay(transactionId: "tx-9")
        let encoded = try FirestoreEncoder().encode(InvoiceMapper().toModel(entity: invoice))
        #expect(encoded["transactionId"] as? String == "tx-9")
        #expect(encoded["status"] as? String == "paid")
        let restored = try InvoiceMapper().toEntity(model: FirestoreDecoder().decode(InvoiceModel.self, from: encoded))
        #expect(restored.status == .paid && restored.transactionId == "tx-9")
        #expect(restored.lineItems == invoice.lineItems)
    }

    // MARK: Checkout session

    @Test("decodes an extension-written session (no orderId, no timestamps)")
    func decodeSession() throws {
        let model = try FirestoreDecoder().decode(CheckoutSessionModel.self, from: F.sessionDocument())
        let session = CheckoutSessionMapper().toEntity(model: model, accountId: F.accountId)
        #expect(session.status == .pending)
        #expect(session.invoiceId.rawValue == F.invoiceId && session.orderId == nil)
        #expect(session.paymentPageURL?.hasPrefix("https://www.liqpay.ua") == true)
        #expect(session.error == nil && session.transactionId == nil)
    }

    @Test("a failed session carries its error fields")
    func failedSession() throws {
        var doc = F.sessionDocument(status: "failure")
        doc["paymentPageURL"] = NSNull()
        doc["errorCode"] = "err_1"
        doc["errorMessage"] = "declined"
        let session = CheckoutSessionMapper().toEntity(
            model: try FirestoreDecoder().decode(CheckoutSessionModel.self, from: doc), accountId: F.accountId
        )
        #expect(session.status == .failure)
        #expect(session.error == CheckoutSessionError(code: "err_1", message: "declined", details: nil))
    }

    @Test("encodes exactly the fields Flutter reads, absent ones as explicit null")
    func encodeSession() throws {
        let session = CheckoutSession(
            invoiceId: .init(rawValue: F.invoiceId), accountId: F.accountId, orderId: .init(rawValue: F.orderId),
            status: .pending, paymentPageURL: nil, transactionId: nil, error: nil
        )
        let encoded = try FirestoreEncoder().encode(CheckoutSessionMapper().toModel(entity: session))
        #expect(Set(encoded.keys) == [
            "status", "invoiceId", "orderId", "paymentPageURL", "transactionId", "errorCode", "errorMessage", "errorDetails",
        ] as Set<String>)
        #expect(encoded["status"] as? String == "pending")
        #expect(encoded["paymentPageURL"] is NSNull && encoded["errorCode"] is NSNull)
        #expect(encoded["orderId"] as? String == F.orderId)
    }

    @Test("the status vocabulary is exactly Flutter's: pending, cancelled, success, failure")
    func sessionVocabulary() {
        #expect(Set(CheckoutSessionStatus.allCases.map(\.rawValue)) == ["pending", "cancelled", "success", "failure"])
        for rejected in ["completed", "expired"] {
            var doc = F.sessionDocument()
            doc["status"] = rejected
            #expect(throws: (any Error).self) { try FirestoreDecoder().decode(CheckoutSessionModel.self, from: doc) }
        }
    }
}
