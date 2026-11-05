import Foundation
import Logging

struct UpdateFeatureUseCase: UseCase {
    struct Params: Sendable {
        let featureId: Feature.Id
        let category: String?
        let name: [String: String]?
        let description: [String: String]?
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any FeatureRepository>
    let mapper: any Mapper<Feature, FeatureModel, FeatureDTO>
    let logger: Logger

    func execute(params: Params) async throws -> FeatureDTO {
        logger.info("Executing UpdateFeatureUseCase", metadata: [
            "featureId": .string(params.featureId.rawValue)
        ])
        let parsed = try Feature.parse(
            category: params.category,
            name: params.name,
            description: params.description
        )

        let repository = repositoryFactory(context)
        guard let feature = try await repository.fetch(byId: params.featureId) else {
            throw ApplicationError.notFound(entity: "Feature", id: params.featureId)
        }

        try feature.update(
            category: parsed.category,
            name: parsed.name,
            description: parsed.description
        )
        try await repository.update(entity: feature)

        return mapper.toDTO(entity: feature)
    }
}
