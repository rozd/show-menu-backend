import Foundation
import FirestoreAPI

/// `invoices/{id}` — Node's `InvoiceModel`: `{id, createdAt, updatedAt, orderId, accountId,
/// customerId, transactionId, status, issueDate, dueDate, orderDate, customer,
/// shipmentMethod, shipmentAddress, lineItems, discounts}` with Firestore `Timestamp`s.
/// `transactionId`, `dueDate` and `shipmentAddress` are explicit `null` when absent.
/// `version` is the template's additive optimistic-concurrency field (D6).
struct InvoiceModel: Codable, Sendable, VersionedModel {
    let id: String
    let createdAt: Timestamp
    let updatedAt: Timestamp
    let orderId: String
    let accountId: String
    let customerId: String
    let transactionId: String?
    let status: InvoiceStatus
    let issueDate: Timestamp
    let dueDate: Timestamp?
    let orderDate: Timestamp
    let customer: CustomerInfo
    let shipmentMethod: ShippingMethod
    let shipmentAddress: String?
    let lineItems: [OrderProduct]
    let discounts: [OrderDiscount]
    var version: Int?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, orderId, accountId, customerId, transactionId, status
        case issueDate, dueDate, orderDate, customer, shipmentMethod, shipmentAddress
        case lineItems, discounts, version
    }

    init(
        id: String, createdAt: Timestamp, updatedAt: Timestamp, orderId: String, accountId: String,
        customerId: String, transactionId: String?, status: InvoiceStatus, issueDate: Timestamp,
        dueDate: Timestamp?, orderDate: Timestamp, customer: CustomerInfo, shipmentMethod: ShippingMethod,
        shipmentAddress: String?, lineItems: [OrderProduct], discounts: [OrderDiscount], version: Int?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.orderId = orderId
        self.accountId = accountId
        self.customerId = customerId
        self.transactionId = transactionId
        self.status = status
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.orderDate = orderDate
        self.customer = customer
        self.shipmentMethod = shipmentMethod
        self.shipmentAddress = shipmentAddress
        self.lineItems = lineItems
        self.discounts = discounts
        self.version = version
    }

    /// Legacy-tolerant: `transactionId`, `dueDate`, `shipmentAddress`, `discounts`, `version` may be absent.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.createdAt = try c.decode(Timestamp.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Timestamp.self, forKey: .updatedAt)
        self.orderId = try c.decode(String.self, forKey: .orderId)
        self.accountId = try c.decode(String.self, forKey: .accountId)
        self.customerId = try c.decode(String.self, forKey: .customerId)
        self.transactionId = try c.decodeIfPresent(String.self, forKey: .transactionId)
        self.status = try c.decode(InvoiceStatus.self, forKey: .status)
        self.issueDate = try c.decode(Timestamp.self, forKey: .issueDate)
        self.dueDate = try c.decodeIfPresent(Timestamp.self, forKey: .dueDate)
        self.orderDate = try c.decode(Timestamp.self, forKey: .orderDate)
        self.customer = try c.decode(CustomerInfo.self, forKey: .customer)
        self.shipmentMethod = try c.decode(ShippingMethod.self, forKey: .shipmentMethod)
        self.shipmentAddress = try c.decodeIfPresent(String.self, forKey: .shipmentAddress)
        self.lineItems = try c.decode([OrderProduct].self, forKey: .lineItems)
        self.discounts = try c.decodeIfPresent([OrderDiscount].self, forKey: .discounts) ?? []
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(orderId, forKey: .orderId)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(customerId, forKey: .customerId)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encode(status, forKey: .status)
        try c.encode(issueDate, forKey: .issueDate)
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(orderDate, forKey: .orderDate)
        try c.encode(customer, forKey: .customer)
        try c.encode(shipmentMethod, forKey: .shipmentMethod)
        try c.encode(shipmentAddress, forKey: .shipmentAddress)
        try c.encode(lineItems, forKey: .lineItems)
        try c.encode(discounts, forKey: .discounts)
        try c.encodeIfPresent(version, forKey: .version)
    }
}
