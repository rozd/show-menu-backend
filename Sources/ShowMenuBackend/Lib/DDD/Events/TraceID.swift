import Foundation

struct TraceID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String

    init() {
        self.rawValue = UUID().hexString
    }

    init(uuid: UUID) {
        self.rawValue = uuid.hexString
    }

    init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else {
            return nil
        }
        self.rawValue = uuid.hexString
    }

    init(stringLiteral value: String) {
        self.rawValue = value
    }

    var description: String {
        rawValue
    }
}

extension TraceID {

    static func generate() -> TraceID {
        TraceID(uuid: UUID())
    }

}

private extension UUID {
    /// 32-char lowercase hex without hyphens — the format Cloud Trace / W3C traceparent expects.
    var hexString: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
