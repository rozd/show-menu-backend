import Foundation
import FirestoreAPI

/// `accounts/{accountId}/orders/{id}` — Node's `OrderModel`: `{id, createdAt, updatedAt,
/// accountId, customerId, lineItems, discounts, shipment{method,address},
/// customer{name,email,phone,address}, status, userInfo, invoiceId}` with Firestore
/// `Timestamp`s. `userInfo` and `invoiceId` are explicit `null` when absent. `version` is
/// the template's additive optimistic-concurrency field (D6).
struct OrderModel: Codable, Sendable, VersionedModel {
    let id: String
    let createdAt: Timestamp
    let updatedAt: Timestamp
    let accountId: String
    let customerId: String
    let lineItems: [OrderProduct]
    let discounts: [OrderDiscount]
    let shipment: ShipmentInfo
    let customer: CustomerInfo
    let status: OrderStatus
    let userInfo: [String: String]?
    let invoiceId: String?
    var version: Int?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, accountId, customerId, lineItems, discounts
        case shipment, customer, status, userInfo, invoiceId, version
    }

    init(
        id: String, createdAt: Timestamp, updatedAt: Timestamp, accountId: String, customerId: String,
        lineItems: [OrderProduct], discounts: [OrderDiscount], shipment: ShipmentInfo, customer: CustomerInfo,
        status: OrderStatus, userInfo: [String: String]?, invoiceId: String?, version: Int?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.accountId = accountId
        self.customerId = customerId
        self.lineItems = lineItems
        self.discounts = discounts
        self.shipment = shipment
        self.customer = customer
        self.status = status
        self.userInfo = userInfo
        self.invoiceId = invoiceId
        self.version = version
    }

    /// Legacy-tolerant: `discounts`, `userInfo`, `invoiceId` and `version` may be absent.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.createdAt = try c.decode(Timestamp.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Timestamp.self, forKey: .updatedAt)
        self.accountId = try c.decode(String.self, forKey: .accountId)
        self.customerId = try c.decode(String.self, forKey: .customerId)
        self.lineItems = try c.decode([OrderProduct].self, forKey: .lineItems)
        self.discounts = try c.decodeIfPresent([OrderDiscount].self, forKey: .discounts) ?? []
        self.shipment = try c.decode(ShipmentInfo.self, forKey: .shipment)
        self.customer = try c.decode(CustomerInfo.self, forKey: .customer)
        self.status = try c.decode(OrderStatus.self, forKey: .status)
        self.userInfo = (try? c.decodeIfPresent([String: String].self, forKey: .userInfo)) ?? nil
        self.invoiceId = try c.decodeIfPresent(String.self, forKey: .invoiceId)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version)
    }

    /// Absent optionals are written as `null`, like Node; `version` is omitted until first set.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(customerId, forKey: .customerId)
        try c.encode(lineItems, forKey: .lineItems)
        try c.encode(discounts, forKey: .discounts)
        try c.encode(shipment, forKey: .shipment)
        try c.encode(customer, forKey: .customer)
        try c.encode(status, forKey: .status)
        try c.encode(userInfo, forKey: .userInfo)
        try c.encode(invoiceId, forKey: .invoiceId)
        try c.encodeIfPresent(version, forKey: .version)
    }
}
