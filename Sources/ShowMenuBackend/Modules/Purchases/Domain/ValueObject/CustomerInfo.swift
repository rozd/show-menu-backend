import Foundation

/// `{name, email, phone, address}`; the optionals are explicit `null` in Node's
/// documents and may be absent in legacy ones.
struct CustomerInfo: Sendable, Hashable, Codable {
    let name: String
    let email: String?
    let phone: String?
    let address: String?

    init(name: String, email: String? = nil, phone: String? = nil, address: String? = nil) {
        self.name = name
        self.email = email
        self.phone = phone
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case name, email, phone, address }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.phone = try c.decodeIfPresent(String.self, forKey: .phone)
        self.address = try c.decodeIfPresent(String.self, forKey: .address)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(phone, forKey: .phone)
        try c.encode(address, forKey: .address)
    }
}

/// `{method, address}` (`address` is explicit `null` when absent).
struct ShipmentInfo: Sendable, Hashable, Codable {
    let method: ShippingMethod
    let address: String?

    init(method: ShippingMethod = .electronic, address: String? = nil) {
        self.method = method
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case method, address }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.method = try c.decode(ShippingMethod.self, forKey: .method)
        self.address = try c.decodeIfPresent(String.self, forKey: .address)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(address, forKey: .address)
    }
}

/// `{discountId}`.
struct OrderDiscount: Sendable, Hashable, Codable {
    let discountId: String
}
