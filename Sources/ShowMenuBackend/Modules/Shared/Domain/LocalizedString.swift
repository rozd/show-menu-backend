import Foundation

/// A `[language: text]` map in which a non-empty Ukrainian (`uk`) entry is required.
///
/// Matches the contract's `LocalizedText`: `uk` required, `en` optional, open to more
/// languages. Codable as a plain JSON map.
struct LocalizedString: Sendable, Hashable, Codable {

    enum Error: ValidationError, Equatable {
        /// No `uk` entry, or it is empty.
        case ukrainianRequired
    }

    /// The language every value must provide.
    static let requiredLanguage = "uk"

    let values: [String: String]

    init(_ values: [String: String]) throws {
        guard let uk = values[Self.requiredLanguage], !uk.isEmpty else { throw Error.ukrainianRequired }
        self.values = values
    }

    subscript(language: String) -> String? { values[language] }

    /// The required Ukrainian text.
    var uk: String { values[Self.requiredLanguage] ?? "" }

    init(from decoder: any Decoder) throws {
        let map = try decoder.singleValueContainer().decode([String: String].self)
        do {
            try self.init(map)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "LocalizedString requires a non-empty 'uk' entry"
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension LocalizedString.Error: LocalizedError {
    var errorDescription: String? { "LocalizedString requires a non-empty 'uk' entry" }
}
