import Foundation
import Logging

struct CreateFeatureUseCase: UseCase {
    struct Params: Sendable {
        let category: String?
        let name: [String: String]?
        let description: [String: String]?
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any FeatureRepository>
    let mapper: any Mapper<Feature, FeatureModel, FeatureDTO>
    let logger: Logger

    func execute(params: Params) async throws -> FeatureDTO {
        logger.info("Executing CreateFeatureUseCase")
        let parsed = try Feature.parse(
            category: params.category,
            name: params.name,
            description: params.description
        )
        guard let category = parsed.category else { throw Feature.Error.categoryRequired }
        guard let name = parsed.name else { throw Feature.Error.nameRequired }

        let feature = try Feature.create(
            category: category,
            name: name,
            description: parsed.description
        )

        let repository = repositoryFactory(context)
        try await repository.insert(entity: feature)

        return mapper.toDTO(entity: feature)
    }
}
