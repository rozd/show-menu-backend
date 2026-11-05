import Foundation

struct CreatePlanCommand: Command {

    /// Request price line: `{price: PriceDTO, duration}` (Node `PlanPriceDTO`).
    /// `duration` is a raw string so an unknown value is a domain `ValidationError` (422).
    struct PriceInput: Sendable, Codable {
        let price: PriceDTO?
        let duration: String?
    }

    struct QuotaInput: Sendable, Codable {
        let unit: String?
        let limit: Double?
    }

    struct FeatureInput: Sendable, Codable {
        let featureId: String?
        let quota: QuotaInput?
    }

    /// Every field is optional so that a missing one surfaces as a domain
    /// `ValidationError` (422) instead of a 400 decoding failure.
    struct Payload: Sendable, Codable {
        let SKU: String?
        let name: [String: String]?
        let description: [String: String]?
        let isActive: Bool?
        let prices: [PriceInput]?
        let features: [FeatureInput]?
    }

    let payload: Payload
    let metadata: CommandMetadata
}
