import Foundation

/// An amount of money in **minor units** (kopiykas, cents) plus its ISO-4217 currency code.
///
/// Integer minor units avoid binary-float drift (19.99 stays exactly 1999).
struct Money: Sendable, Hashable, Codable {

    enum Error: ValidationError, Equatable {
        case negativeAmount
        case invalidCurrency(String)
    }

    /// Minor units, always >= 0.
    let amount: Int64
    /// ISO-4217 alphabetic code, `^[A-Z]{3}$`.
    let currency: String

    init(amount: Int64, currency: String) throws {
        guard amount >= 0 else { throw Error.negativeAmount }
        guard Self.isValid(currency: currency) else { throw Error.invalidCurrency(currency) }
        self.amount = amount
        self.currency = currency
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                amount: container.decode(Int64.self, forKey: .amount),
                currency: container.decode(String.self, forKey: .currency)
            )
        } catch let error as Error {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: error.localizedDescription
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case amount, currency
    }

    private static func isValid(currency: String) -> Bool {
        let bytes = Array(currency.utf8)
        return bytes.count == 3 && bytes.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }
    }

    /// The amount as a decimal string with exactly 2 fraction digits (`39000` -> `"390.00"`,
    /// `5` -> `"0.05"`).
    ///
    /// Assumption: every supported currency has 2 minor-unit digits (UAH, the only currency
    /// the product sells in). Currencies with other exponents (JPY, KWD) are not handled.
    var decimalString: String {
        let whole = amount / 100
        let fraction = amount % 100
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

extension Money.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .negativeAmount: "Money amount must not be negative"
        case let .invalidCurrency(code): "Currency must be a 3-letter uppercase ISO-4217 code, got '\(code)'"
        }
    }
}
