import Foundation
import FirestoreAPI

struct PlanMapper: Mapper, Sendable {
    typealias Entity = Plan
    typealias Model = PlanModel
    typealias DTO = PlanDTO

    init() {}

    func toModel(entity: Plan) -> PlanModel {
        PlanModel(
            id: entity.id.rawValue,
            SKU: entity.SKU,
            name: entity.name,
            description: entity.description,
            isActive: entity.isActive,
            prices: entity.prices,
            features: entity.features,
            version: entity.version.versionInt,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt)
        )
    }

    func toEntity(model: PlanModel) throws -> Plan {
        Plan(
            id: Plan.Id(rawValue: model.id),
            SKU: model.SKU,
            name: model.name,
            description: model.description,
            isActive: model.isActive,
            prices: model.prices,
            features: model.features,
            version: Version(versionInt: model.version),
            createdAt: model.createdAt.asDate,
            updatedAt: model.updatedAt.asDate
        )
    }

    func toDTO(entity: Plan) -> PlanDTO {
        PlanDTO(
            id: entity.id.rawValue,
            createdAt: FeatureMapper.iso(entity.createdAt),
            updatedAt: FeatureMapper.iso(entity.updatedAt),
            SKU: entity.SKU,
            name: entity.name.values,
            description: entity.description.values,
            isActive: entity.isActive,
            prices: entity.prices.map { PlanPriceDTO(price: $0.price, duration: $0.duration.rawValue) },
            features: entity.features.map { PlanFeatureDTO(featureId: $0.featureId.rawValue, quota: $0.quota) }
        )
    }

    func toDTO(model: PlanModel) -> PlanDTO {
        PlanDTO(
            id: model.id,
            createdAt: FeatureMapper.iso(model.createdAt.asDate),
            updatedAt: FeatureMapper.iso(model.updatedAt.asDate),
            SKU: model.SKU,
            name: model.name.values,
            description: model.description.values,
            isActive: model.isActive,
            prices: model.prices.map { PlanPriceDTO(price: $0.price, duration: $0.duration.rawValue) },
            features: model.features.map { PlanFeatureDTO(featureId: $0.featureId.rawValue, quota: $0.quota) }
        )
    }
}
