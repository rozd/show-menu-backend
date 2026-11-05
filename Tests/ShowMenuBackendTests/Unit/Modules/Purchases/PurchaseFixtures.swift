import Foundation
import FirestoreAPI
@testable import ShowMenuBackend

/// Documents shaped exactly like the ones Node (Admin SDK) and the LiqPay extension write:
/// whole numbers as integers, absent optionals as explicit `null`.
enum PurchaseFixtures {
    static let created = Timestamp(seconds: 1_767_225_600, nanos: 123_000_000) // 2026-01-01T00:00:00.123Z
    static let updated = Timestamp(seconds: 1_767_229_200, nanos: 5_000_000)

    static let orderId = "order-0a1b2c3d-0000-4000-8000-000000000001"
    static let invoiceId = "invoice-0a1b2c3d-0000-4000-8000-000000000002"
    static let accountId = "account-1"
    static let customerId = "uid-1"

    static func planLine(duration: Bool = true) -> [String: Any] {
        var line: [String: Any] = [
            "sku": "SKU-1",
            "productId": "plan-0a1b2c3d-0000-4000-8000-000000000003",
            "productName": ["en": "Pro", "uk": "Про"],
            "productPrice": [
                "currency": ["symbol": "$", "name": "USD", "base": 100, "digits": 2] as [String: Any],
                "amount": 2900,
            ] as [String: Any],
            "quantity": 1,
        ]
        if duration { line["duration"] = "monthly" }
        return line
    }

    static func customer() -> [String: Any] {
        ["name": "Max", "email": "max@example.com", "phone": NSNull(), "address": NSNull()]
    }

    /// `accounts/{a}/orders/{id}` as `OrderMapper.toPersistence` writes it.
    static func orderDocument() -> [String: Any] {
        [
            "id": orderId,
            "createdAt": created,
            "updatedAt": updated,
            "accountId": accountId,
            "customerId": customerId,
            "lineItems": [planLine()],
            "discounts": [] as [Any],
            "shipment": ["method": "electronic", "address": "max@example.com"],
            "customer": customer(),
            "status": "created",
            "userInfo": NSNull(),
            "invoiceId": invoiceId,
        ]
    }

    /// `invoices/{id}` as `InvoiceMapper.toPersistence` writes it.
    static func invoiceDocument() -> [String: Any] {
        [
            "id": invoiceId,
            "createdAt": created,
            "updatedAt": updated,
            "orderId": orderId,
            "accountId": accountId,
            "customerId": customerId,
            "transactionId": NSNull(),
            "status": "pending",
            "issueDate": created,
            "dueDate": NSNull(),
            "orderDate": created,
            "customer": customer(),
            "shipmentMethod": "electronic",
            "shipmentAddress": "max@example.com",
            "lineItems": [planLine()],
            "discounts": [] as [Any],
        ]
    }

    /// `accounts/{a}/checkout-sessions/{invoiceId}` as the LiqPay extension writes it (no `orderId`, no timestamps).
    static func sessionDocument(status: String = "pending") -> [String: Any] {
        [
            "status": status,
            "invoiceId": invoiceId,
            "paymentPageURL": "https://www.liqpay.ua/api/3/checkout?data=x&signature=y",
            "transactionId": NSNull(),
            "errorCode": NSNull(),
            "errorMessage": NSNull(),
            "errorDetails": NSNull(),
        ]
    }

    // MARK: Domain builders

    static func product(duration: SubscriptionDuration? = .monthly, amount: Double = 2900, quantity: Int = 1) throws -> OrderProduct {
        try OrderProduct(
            sku: "SKU-1",
            productId: "plan-1",
            productName: LocalizedString(["en": "Pro"]),
            productPrice: Price(currency: Currency(name: "USD", symbol: "$", base: 100, digits: 2), amount: amount),
            quantity: quantity,
            duration: duration
        )
    }

    static func makeOrder(lines: [OrderProduct]? = nil, now: Date = Date(timeIntervalSince1970: 1_767_225_600.123)) throws -> Order {
        try Order.create(
            accountId: accountId,
            customerId: .init(rawValue: customerId),
            lineItems: try lines ?? [product()],
            shipment: ShipmentInfo(method: .electronic, address: "max@example.com"),
            customer: CustomerInfo(name: "Max", email: "max@example.com"),
            now: now
        )
    }
}
