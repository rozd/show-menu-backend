import Foundation

struct PurchaseSubscriptionCommand: Command {

    /// Flat price as the client sends it (`PriceDTO` shape). Every field is optional so a
    /// missing one is a domain `ValidationError` (422), not a 400 decoding failure.
    struct PriceInput: Sendable, Codable {
        let currencyName: String?
        let currencySymbol: String?
        let currencyBase: Int?
        let currencyDigits: Int?
        let amount: Double?
    }

    /// `{price: PriceDTO, duration}` (Node `PlanPriceDTO`).
    struct PlanPriceInput: Sendable, Codable {
        let price: PriceInput?
        let duration: String?
    }

    /// Unknown fields (Node's `customerName`, `customerEmail`, `discounts`) are ignored.
    struct Payload: Sendable, Codable {
        let planId: String?
        let price: PlanPriceInput?
    }

    enum Error: ValidationError, LocalizedError, Equatable {
        case planIdRequired
        case priceRequired
        case currencyNameRequired
        case amountRequired

        var errorDescription: String? {
            switch self {
            case .planIdRequired: "planId is required"
            case .priceRequired: "price is required"
            case .currencyNameRequired: "price.price.currencyName is required"
            case .amountRequired: "price.price.amount is required"
            }
        }
    }

    /// Route parameter: the account the subscription is bought for.
    let accountId: String
    /// The token's email, the fallback when `users/{uid}` does not exist yet. Request
    /// metadata, deliberately outside `payload` (not part of the idempotency fingerprint).
    let customerEmail: String?
    let payload: Payload
    let metadata: CommandMetadata
}

extension PurchaseSubscriptionCommand.Payload {

    /// Parses the requested price line; every failure is a `ValidationError` (422).
    func requestedPrice() throws -> PlanPrice {
        guard let line = price else { throw PurchaseSubscriptionCommand.Error.priceRequired }
        guard let inner = line.price else { throw PurchaseSubscriptionCommand.Error.priceRequired }
        guard let currencyName = inner.currencyName else { throw PurchaseSubscriptionCommand.Error.currencyNameRequired }
        guard let amount = inner.amount else { throw PurchaseSubscriptionCommand.Error.amountRequired }
        let dto = PriceDTO(
            currencyName: currencyName, currencySymbol: inner.currencySymbol,
            currencyBase: inner.currencyBase, currencyDigits: inner.currencyDigits, amount: amount
        )
        return PlanPrice(price: try dto.toPrice(), duration: try Plan.parseDuration(line.duration))
    }
}
