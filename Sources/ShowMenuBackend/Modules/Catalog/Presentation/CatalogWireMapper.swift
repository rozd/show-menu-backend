import Foundation
import ShowMenuContracts

/// Catalog's mapping between the generated wire schemas and the Application layer.
///
/// Generated types stop here: controllers take/return `Components.Schemas.*`, everything
/// below speaks DTOs and command payloads. A stored value that cannot be expressed on the
/// wire (an unknown category/duration string, a bad date) is a data-integrity fault and throws
/// ``CatalogWireError`` (a 500), never a client error.
enum CatalogWireMapper {

    struct CatalogWireError: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    // MARK: - DTO → wire

    static func localized(_ map: [String: String]) -> Components.Schemas.LocalizedString {
        .init(additionalProperties: map)
    }

    static func wire(_ dto: FeatureDTO) throws -> Components.Schemas.Feature {
        guard let category = Components.Schemas.FeatureCategory(rawValue: dto.category) else {
            throw CatalogWireError(description: "Unknown feature category \(dto.category)")
        }
        return .init(
            id: dto.id,
            createdAt: try Date.parseISOOrThrow(dto.createdAt),
            updatedAt: try Date.parseISOOrThrow(dto.updatedAt),
            category: category,
            name: localized(dto.name),
            description: dto.description.map(localized)
        )
    }

    static func wire(_ dto: PlanDTO) throws -> Components.Schemas.Plan {
        .init(
            id: dto.id,
            createdAt: try Date.parseISOOrThrow(dto.createdAt),
            updatedAt: try Date.parseISOOrThrow(dto.updatedAt),
            sku: dto.SKU,
            name: localized(dto.name),
            description: localized(dto.description),
            isActive: dto.isActive,
            prices: try dto.prices.map(wire),
            features: try dto.features.map(wire)
        )
    }

    private static func wire(_ dto: PlanPriceDTO) throws -> Components.Schemas.PlanPrice {
        guard let duration = Components.Schemas.SubscriptionDuration(rawValue: dto.duration) else {
            throw CatalogWireError(description: "Unknown subscription duration \(dto.duration)")
        }
        return .init(
            price: .init(
                currency: .init(
                    name: dto.price.currency.name,
                    symbol: dto.price.currency.symbol,
                    base: dto.price.currency.base,
                    digits: dto.price.currency.digits
                ),
                amount: dto.price.amount
            ),
            duration: duration
        )
    }

    private static func wire(_ dto: PlanFeatureDTO) throws -> Components.Schemas.PlanFeature {
        guard let unit = Components.Schemas.FeatureQuota.UnitPayload(rawValue: dto.quota.unit.rawValue) else {
            throw CatalogWireError(description: "Unknown quota unit \(dto.quota.unit.rawValue)")
        }
        return .init(featureId: dto.featureId, quota: .init(unit: unit, limit: dto.quota.limit))
    }

    // MARK: - Wire → command payloads

    static func payload(_ body: Components.Schemas.CreateFeatureRequest) -> CreateFeatureCommand.Payload {
        .init(
            category: body.category.rawValue,
            name: body.name.additionalProperties,
            description: body.description?.additionalProperties
        )
    }

    static func payload(_ body: Components.Schemas.UpdateFeatureRequest) -> UpdateFeatureCommand.Payload {
        .init(
            category: body.category?.rawValue,
            name: body.name?.additionalProperties,
            description: body.description?.additionalProperties
        )
    }

    static func payload(_ body: Components.Schemas.CreatePlanRequest) -> CreatePlanCommand.Payload {
        .init(
            SKU: body.sku,
            name: body.name.additionalProperties,
            description: body.description.additionalProperties,
            isActive: body.isActive,
            prices: body.prices.map { line in
                .init(
                    price: .init(
                        currencyName: line.price.currencyName,
                        currencySymbol: line.price.currencySymbol,
                        currencyBase: line.price.currencyBase,
                        currencyDigits: line.price.currencyDigits,
                        amount: line.price.amount
                    ),
                    duration: line.duration.rawValue
                )
            },
            features: body.features.map(featureInput)
        )
    }

    static func payload(_ body: Components.Schemas.UpdatePlanRequest) -> UpdatePlanCommand.Payload {
        .init(name: body.name.additionalProperties, description: body.description.additionalProperties)
    }

    static func payload(_ body: Components.Schemas.PlanFeatureInput) -> AddPlanFeatureCommand.Payload {
        featureInput(body)
    }

    private static func featureInput(_ body: Components.Schemas.PlanFeatureInput) -> CreatePlanCommand.FeatureInput {
        .init(
            featureId: body.featureId,
            quota: .init(unit: body.quota.unit.rawValue, limit: body.quota.limit)
        )
    }
}
