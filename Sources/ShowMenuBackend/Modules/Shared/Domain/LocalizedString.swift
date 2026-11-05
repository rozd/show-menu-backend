import Foundation

/// A non-empty `[language: text]` map. Codable as a plain JSON/Firestore map,
/// exactly like Node's `LocalizedString` (`{ [key: string]: string }`).
struct LocalizedString: Sendable, Hashable, Codable {

    enum Error: ValidationError, Equatable {
        case empty
    }

    let values: [String: String]

    init(_ values: [String: String]) throws {
        guard !values.isEmpty else { throw Error.empty }
        self.values = values
    }

    subscript(language: String) -> String? { values[language] }

    init(from decoder: any Decoder) throws {
        let map = try decoder.singleValueContainer().decode([String: String].self)
        guard !map.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "LocalizedString must contain at least one entry"
            ))
        }
        self.values = map
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension LocalizedString.Error: LocalizedError {
    var errorDescription: String? { "LocalizedString must contain at least one entry" }
}
