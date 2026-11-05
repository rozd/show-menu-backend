import Foundation

/// Mirrors Node's `CurrencyProps`: `{symbol, name, base, digits}` where the
/// optional members are stored as explicit `null` (not omitted).
struct Currency: Sendable, Hashable, Codable {

    enum Error: ValidationError, Equatable {
        case nameRequired
    }

    let name: String
    let symbol: String?
    let base: Int?
    let digits: Int?

    init(name: String, symbol: String? = nil, base: Int? = nil, digits: Int? = nil) throws {
        guard !name.isEmpty else { throw Error.nameRequired }
        self.name = name
        self.symbol = symbol
        self.base = base
        self.digits = digits
    }

    private enum CodingKeys: String, CodingKey { case symbol, name, base, digits }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Currency name is required")
        }
        self.name = name
        self.symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        self.base = try c.decodeIfPresent(Int.self, forKey: .base)
        self.digits = try c.decodeIfPresent(Int.self, forKey: .digits)
    }

    /// Writes `null` for absent optionals so the stored shape equals Node's.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(name, forKey: .name)
        try c.encode(base, forKey: .base)
        try c.encode(digits, forKey: .digits)
    }
}

extension Currency.Error: LocalizedError {
    var errorDescription: String? { "Currency name is required" }
}
