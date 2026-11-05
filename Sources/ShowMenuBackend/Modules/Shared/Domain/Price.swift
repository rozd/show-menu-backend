import Foundation

/// `{currency, amount}` with `amount >= 0` (Node's `Price`; the `> 0` rule
/// lives on the DTO, not the value object).
struct Price: Sendable, Hashable, Codable {

    enum Error: ValidationError, Equatable {
        case negativeAmount
    }

    let currency: Currency
    let amount: Double

    init(currency: Currency, amount: Double) throws {
        guard amount >= 0 else { throw Error.negativeAmount }
        self.currency = currency
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey { case currency, amount }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let currency = try c.decode(Currency.self, forKey: .currency)
        let amount = try c.decodeJSNumber(forKey: .amount)
        guard amount >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: c, debugDescription: "Price cannot be negative")
        }
        self.currency = currency
        self.amount = amount
    }

    /// Whole amounts are written as integers, like a JS `number` (see `encodeJSNumber`).
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(currency, forKey: .currency)
        try c.encodeJSNumber(amount, forKey: .amount)
    }
}

extension Price.Error: LocalizedError {
    var errorDescription: String? { "Price cannot be negative" }
}
