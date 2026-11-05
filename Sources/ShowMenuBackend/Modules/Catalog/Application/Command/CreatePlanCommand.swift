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

extension CreatePlanCommand.FeatureInput {
    /// Parses the raw request line into a `PlanFeature`; every failure is a
    /// `ValidationError` (422).
    func toPlanFeature() throws -> PlanFeature {
        guard let featureId, !featureId.isEmpty else { throw Plan.Error.featureIdRequired }
        guard let quota, let limit = quota.limit else { throw Plan.Error.quotaRequired }
        return PlanFeature(
            featureId: Feature.Id(rawValue: featureId),
            quota: FeatureQuota(unit: try Plan.parseQuotaUnit(quota.unit), limit: limit)
        )
    }
}
