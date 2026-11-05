import Foundation

extension KeyedEncodingContainer {

    /// Encodes `value` the way Node's Admin SDK stores a JS `number`: a whole
    /// value as an integer (Firestore `integerValue`), anything else as a double.
    /// Flutter casts some of these fields (`as int?`, `(as num).toInt()`), so the
    /// stored value kind is part of the contract.
    mutating func encodeJSNumber(_ value: Double, forKey key: Key) throws {
        if value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
            try encode(Int64(value), forKey: key)
        } else {
            try encode(value, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {

    /// Decodes a JS-style number stored as either a Firestore `doubleValue` or an
    /// `integerValue` (Node writes whole numbers as integers).
    func decodeJSNumber(forKey key: Key) throws -> Double {
        if let double = try? decode(Double.self, forKey: key) { return double }
        return Double(try decode(Int64.self, forKey: key))
    }
}
