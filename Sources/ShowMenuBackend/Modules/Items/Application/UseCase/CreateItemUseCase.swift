import Foundation
import Logging

struct CreateItemUseCase: UseCase {
    struct Params: Sendable {
        let name: String
        let description: String?
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any ItemRepository>
    let mapper: any Mapper<Item, ItemModel, ItemDTO>
    let logger: Logger

    func execute(params: Params) async throws -> ItemDTO {
        logger.info("Executing CreateItemUseCase")
        try Item.validate(name: params.name)

        let item = Item(
            id: .generate(),
            name: params.name,
            description: params.description,
        )

        let repository = repositoryFactory(context)
        try await repository.insert(entity: item)

        return mapper.toDTO(entity: item)
    }
}
