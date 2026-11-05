import Foundation
import FirestoreAPI

struct FeatureMapper: Mapper, Sendable {
    typealias Entity = Feature
    typealias Model = FeatureModel
    typealias DTO = FeatureDTO

    init() {}

    func toModel(entity: Feature) -> FeatureModel {
        FeatureModel(
            id: entity.id.rawValue,
            category: entity.category,
            name: entity.name,
            description: entity.description,
            version: entity.version.versionInt,
            createdAt: Timestamp(exact: entity.createdAt),
            updatedAt: Timestamp(exact: entity.updatedAt)
        )
    }

    func toEntity(model: FeatureModel) throws -> Feature {
        Feature(
            id: Feature.Id(rawValue: model.id),
            category: model.category,
            name: model.name,
            description: model.description,
            version: Version(versionInt: model.version),
            createdAt: model.createdAt.asDate,
            updatedAt: model.updatedAt.asDate
        )
    }

    func toDTO(entity: Feature) -> FeatureDTO {
        FeatureDTO(
            id: entity.id.rawValue,
            createdAt: Self.iso(entity.createdAt),
            updatedAt: Self.iso(entity.updatedAt),
            category: entity.category.rawValue,
            name: entity.name.values,
            description: entity.description?.values
        )
    }

    func toDTO(model: FeatureModel) -> FeatureDTO {
        FeatureDTO(
            id: model.id,
            createdAt: Self.iso(model.createdAt.asDate),
            updatedAt: Self.iso(model.updatedAt.asDate),
            category: model.category.rawValue,
            name: model.name.values,
            description: model.description?.values
        )
    }

    /// JS `Date.toISOString()` form: `2026-01-02T03:04:05.678Z`.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
