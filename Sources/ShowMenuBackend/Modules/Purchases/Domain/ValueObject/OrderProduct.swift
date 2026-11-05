import Foundation

/// One purchased line (Node's `OrderProduct` / `PlanOrderProduct`).
///
/// Node discriminates the two by `hasOwnProperty("duration")`, so a plan line is the
/// same struct with `duration` set (see ``PlanOrderProduct``). The Codable shape is
/// Node's exactly: `{sku, productId, productName, productPrice{currency{…},amount},
/// quantity, duration?, productDetails?}`; `duration` and `productDetails` are omitted
/// (not `null`) when absent.
struct OrderProduct: Sendable, Hashable, Codable {

    enum Error: ValidationError, LocalizedError, Equatable {
        case skuRequired
        case productIdRequired
        case invalidQuantity

        var errorDescription: String? {
            switch self {
            case .skuRequired: "SKU is required"
            case .productIdRequired: "Product ID is required"
            case .invalidQuantity: "Quantity must be greater than 0"
            }
        }
    }

    let sku: String
    let productId: String
    let productName: LocalizedString
    let productPrice: Price
    let quantity: Int
    /// Set for plan (subscription) lines.
    let duration: SubscriptionDuration?
    /// Free-form details; Node never writes them. Only string values are kept.
    let productDetails: [String: String]?

    init(
        sku: String,
        productId: String,
        productName: LocalizedString,
        productPrice: Price,
        quantity: Int,
        duration: SubscriptionDuration? = nil,
        productDetails: [String: String]? = nil
    ) throws {
        guard !sku.isEmpty else { throw Error.skuRequired }
        guard !productId.isEmpty else { throw Error.productIdRequired }
        guard quantity > 0 else { throw Error.invalidQuantity }
        self.sku = sku
        self.productId = productId
        self.productName = productName
        self.productPrice = productPrice
        self.quantity = quantity
        self.duration = duration
        self.productDetails = productDetails
    }

    /// `unit price x quantity`.
    var totalAmount: Double { productPrice.amount * Double(quantity) }

    private enum CodingKeys: String, CodingKey {
        case sku, productId, productName, productPrice, quantity, duration, productDetails
    }

    /// Legacy-tolerant: `duration` / `productDetails` may be absent; unreadable
    /// `productDetails` (non-string values) are dropped rather than failing the document.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sku = try c.decode(String.self, forKey: .sku)
        self.productId = try c.decode(String.self, forKey: .productId)
        self.productName = try c.decode(LocalizedString.self, forKey: .productName)
        self.productPrice = try c.decode(Price.self, forKey: .productPrice)
        self.quantity = Int(try c.decodeJSNumber(forKey: .quantity))
        self.duration = try c.decodeIfPresent(SubscriptionDuration.self, forKey: .duration)
        self.productDetails = (try? c.decodeIfPresent([String: String].self, forKey: .productDetails)) ?? nil
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sku, forKey: .sku)
        try c.encode(productId, forKey: .productId)
        try c.encode(productName, forKey: .productName)
        try c.encode(productPrice, forKey: .productPrice)
        try c.encode(quantity, forKey: .quantity)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(productDetails, forKey: .productDetails)
    }
}

/// Node's `PlanOrderProduct`: an ``OrderProduct`` with a subscription `duration`.
enum PlanOrderProduct {

    /// `PlanOrderProduct.fromPlanAndPrice`: one unit of the plan at the chosen price.
    static func from(plan: Plan, price: PlanPrice) throws -> OrderProduct {
        try OrderProduct(
            sku: plan.SKU,
            productId: plan.id.rawValue,
            productName: plan.name,
            productPrice: price.price,
            quantity: 1,
            duration: price.duration
        )
    }
}

// MARK: - What checkout and invoicing need from the lines

extension Collection where Element == OrderProduct {

    /// Σ unit price × quantity.
    var totalAmount: Double { reduce(0) { $0 + $1.totalAmount } }

    /// The first line's currency (Node: `lineItems[0].totalPrice.currency`).
    var currency: Currency? { first?.productPrice.currency }

    /// `subscribe` when the first line is a plan line, else `pay`.
    var paymentAction: PaymentAction { first?.duration == nil ? .pay : .subscribe }

    /// The first line's subscription period, if it is a plan line.
    var subscriptionDuration: SubscriptionDuration? { first?.duration }

    /// The primitives ``CheckoutRequest`` is built from.
    var checkoutLines: [CheckoutLine] {
        map {
            CheckoutLine(
                amount: $0.productPrice.amount,
                quantity: $0.quantity,
                currencyName: $0.productPrice.currency.name,
                duration: $0.duration
            )
        }
    }
}
