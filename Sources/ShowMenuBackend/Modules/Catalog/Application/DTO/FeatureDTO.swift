import Foundation

/// Node's `FeatureResponse`: `{id, createdAt, updatedAt, category, name, description?}`.
/// Dates are `toISOString()` strings (UTC, millisecond precision); `description`
/// is omitted when absent.
struct FeatureDTO: Sendable, Codable, Equatable {
    let id: String
    let createdAt: String
    let updatedAt: String
    let category: String
    let name: [String: String]
    let description: [String: String]?
}
