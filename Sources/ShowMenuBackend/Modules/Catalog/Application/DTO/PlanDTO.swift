import Foundation

/// Node's `PlanResponse`: `{id, createdAt, updatedAt, SKU, name, description,
/// isActive, prices, features}`. Dates are `toISOString()` strings. `prices` and
/// `features` keep the nested stored shape (`prices[].price.currency{…}`).
struct PlanDTO: Sendable, Codable, Equatable {
    let id: String
    let createdAt: String
    let updatedAt: String
    let SKU: String
    let name: [String: String]
    let description: [String: String]
    let isActive: Bool
    let prices: [PlanPriceDTO]
    let features: [PlanFeatureDTO]
}

struct PlanPriceDTO: Sendable, Codable, Equatable {
    let price: Price
    let duration: String
}

struct PlanFeatureDTO: Sendable, Codable, Equatable {
    let featureId: String
    let quota: FeatureQuota
}
