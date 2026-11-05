import Foundation

/// Unit a feature quota is measured in. Raw values equal Node's
/// `FeatureQuotaUnitValues`.
enum FeatureQuotaUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case duration, count, level
}

/// `{unit, limit}` — Node's `FeatureQuota`. A limit `<= 0` means unlimited.
struct FeatureQuota: Sendable, Hashable, Codable {
    let unit: FeatureQuotaUnit
    let limit: Double

    var isUnlimited: Bool { limit <= 0 }

    private enum CodingKeys: String, CodingKey { case unit, limit }

    init(unit: FeatureQuotaUnit, limit: Double) {
        self.unit = unit
        self.limit = limit
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.unit = try c.decode(FeatureQuotaUnit.self, forKey: .unit)
        self.limit = try c.decodeJSNumber(forKey: .limit)
    }

    /// Whole limits are written as integers, like a JS `number`.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        try c.encodeJSNumber(limit, forKey: .limit)
    }
}

/// A feature granted by a plan with its quota: `{featureId, quota}`.
struct PlanFeature: Sendable, Hashable, Codable {
    let featureId: Feature.Id
    let quota: FeatureQuota

    private enum CodingKeys: String, CodingKey { case featureId, quota }

    init(featureId: Feature.Id, quota: FeatureQuota) {
        self.featureId = featureId
        self.quota = quota
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.featureId = Feature.Id(rawValue: try c.decode(String.self, forKey: .featureId))
        self.quota = try c.decode(FeatureQuota.self, forKey: .quota)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(featureId.rawValue, forKey: .featureId)
        try c.encode(quota, forKey: .quota)
    }
}
