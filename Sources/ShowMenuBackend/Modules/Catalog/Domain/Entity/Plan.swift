import Foundation

/// Subscription plan (`plans/{id}`).
///
/// Invariants (Node `Plan.validate`): non-empty SKU; at least one price and one
/// feature; unique price durations and unique feature ids. Violations are
/// `ValidationError`s (422).
final class Plan: AggregateRoot, @unchecked Sendable {
    typealias Event = PlanEvent

    let id: Plan.Id
    let events: DomainEventRecorder<Event> = .init()

    /// Opaque optimistic-concurrency token; set by the persistence layer.
    var version: Version = .none

    let SKU: String
    private(set) var name: LocalizedString
    private(set) var description: LocalizedString
    private(set) var isActive: Bool
    private(set) var prices: [PlanPrice]
    private(set) var features: [PlanFeature]
    private(set) var createdAt: Date
    private(set) var updatedAt: Date

    /// Rehydration initializer (no validation, no events): used by the mapper.
    init(
        id: Plan.Id,
        SKU: String,
        name: LocalizedString,
        description: LocalizedString,
        isActive: Bool,
        prices: [PlanPrice],
        features: [PlanFeature],
        version: Version = .none,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.SKU = SKU
        self.name = name
        self.description = description
        self.isActive = isActive
        self.prices = prices
        self.features = features
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Creates a new plan and records the semantic `PlanCreated` event. The
    /// lifecycle `created` event is recorded by the Repository on insert.
    static func create(
        SKU: String,
        name: LocalizedString,
        description: LocalizedString,
        isActive: Bool,
        prices: [PlanPrice],
        features: [PlanFeature],
        now: Date = .now
    ) throws -> Plan {
        let plan = Plan(
            id: .generate(),
            SKU: SKU,
            name: name,
            description: description,
            isActive: isActive,
            prices: prices,
            features: features,
            createdAt: now,
            updatedAt: now
        )
        try plan.validate()
        plan.record(event: .planAdded(aggregateId: plan.id))
        return plan
    }

    /// D9: a purchase price matches a plan price when **duration + currency name
    /// + amount** are equal. Symbol / base / digits are deliberately ignored
    /// (Flutter omits base and digits).
    func matches(price: PlanPrice) -> Bool {
        prices.contains {
            $0.duration == price.duration
                && $0.price.currency.name == price.price.currency.name
                && $0.price.amount == price.price.amount
        }
    }

    func validate() throws {
        try Plan.validate(SKU: SKU, prices: prices, features: features)
    }
}

extension Plan {
    struct Id: PrefixedEntityId {
        static let prefix = "plan-"

        let rawValue: String
        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension Plan {
    enum Error: ValidationError, LocalizedError, Equatable {
        case skuRequired
        case nameRequired
        case descriptionRequired
        case isActiveRequired
        case pricesRequired
        case featuresRequired
        case duplicateFeatures
        case duplicateDurations
        case invalidDuration(String)
        case invalidQuotaUnit(String)
        case quotaRequired
        case featureIdRequired

        var errorDescription: String? {
            switch self {
            case .skuRequired: "Plan must have a SKU"
            case .nameRequired: "Plan name is required"
            case .descriptionRequired: "Plan description is required"
            case .isActiveRequired: "Plan isActive is required"
            case .pricesRequired: "Plan must have at least one price"
            case .featuresRequired: "Plan must have at least one feature"
            case .duplicateFeatures: "Plan cannot have duplicate features"
            case .duplicateDurations: "Plan cannot have duplicate durations"
            case .invalidDuration(let value):
                "Duration must be one of: \(SubscriptionDuration.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(value)')"
            case .invalidQuotaUnit(let value):
                "Quota unit must be one of: \(FeatureQuotaUnit.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(value)')"
            case .quotaRequired: "Plan feature quota is required"
            case .featureIdRequired: "Plan feature id is required"
            }
        }
    }

    static func validate(SKU: String, prices: [PlanPrice], features: [PlanFeature]) throws {
        guard !SKU.isEmpty else { throw Error.skuRequired }
        guard !features.isEmpty else { throw Error.featuresRequired }
        guard !prices.isEmpty else { throw Error.pricesRequired }
        let featureIds = features.map(\.featureId.rawValue)
        guard featureIds.count == Set(featureIds).count else { throw Error.duplicateFeatures }
        let durations = prices.map(\.duration)
        guard durations.count == Set(durations).count else { throw Error.duplicateDurations }
    }

    /// Parses raw request values into value objects; every failure is a
    /// `ValidationError` (422), including missing fields.
    static func parseDuration(_ raw: String?) throws -> SubscriptionDuration {
        guard let raw, let value = SubscriptionDuration(rawValue: raw) else {
            throw Error.invalidDuration(raw ?? "")
        }
        return value
    }

    static func parseQuotaUnit(_ raw: String?) throws -> FeatureQuotaUnit {
        guard let raw, let value = FeatureQuotaUnit(rawValue: raw) else {
            throw Error.invalidQuotaUnit(raw ?? "")
        }
        return value
    }
}
