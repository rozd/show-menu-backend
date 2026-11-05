import Foundation

/// Flat wire shape of a price (Node `PriceDTO`). Currency symbol/base/digits
/// are optional (D9: Flutter omits base/digits).
struct PriceDTO: Codable, Sendable, Hashable {
    let currencyName: String
    let currencySymbol: String?
    let currencyBase: Int?
    let currencyDigits: Int?
    let amount: Double

    init(currencyName: String, currencySymbol: String? = nil, currencyBase: Int? = nil,
         currencyDigits: Int? = nil, amount: Double) {
        self.currencyName = currencyName
        self.currencySymbol = currencySymbol
        self.currencyBase = currencyBase
        self.currencyDigits = currencyDigits
        self.amount = amount
    }

    init(_ price: Price) {
        self.init(currencyName: price.currency.name, currencySymbol: price.currency.symbol,
                  currencyBase: price.currency.base, currencyDigits: price.currency.digits,
                  amount: price.amount)
    }

    /// Edge validation (Node: `currencyName` string ≥ 3 chars, `amount` > 0).
    /// Throws `PriceDTO.Error` (a `ValidationError` → 422).
    func validate() throws {
        guard currencyName.count >= 3 else { throw Error.currencyNameTooShort }
        guard amount > 0 else { throw Error.amountNotPositive }
    }

    func toPrice() throws -> Price {
        try validate()
        return try Price(
            currency: Currency(name: currencyName, symbol: currencySymbol, base: currencyBase, digits: currencyDigits),
            amount: amount
        )
    }

    enum Error: ValidationError, Equatable, LocalizedError {
        case currencyNameTooShort
        case amountNotPositive

        var errorDescription: String? {
            switch self {
            case .currencyNameTooShort: "currencyName must be at least 3 characters"
            case .amountNotPositive: "amount must be a positive number"
            }
        }
    }
}
