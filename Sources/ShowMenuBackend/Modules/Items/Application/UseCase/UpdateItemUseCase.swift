import Foundation
import Logging

struct UpdateItemUseCase: UseCase {
    struct Params: Sendable {
        let itemId: Item.Id
        /// If non-nil, the caller's `If-Match` precondition — pinned as the
        /// expected token so a stale edit fails the check-and-set.
        let expectedEntityVersion: Version?
        let name: String
        let description: String?
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any ItemRepository>
    let mapper: any Mapper<Item, ItemModel, ItemDTO>
    let logger: Logger

    func execute(params: Params) async throws -> ItemDTO {
        logger.info("Executing UpdateItemUseCase", metadata: [
            "itemId": .string(params.itemId.rawValue)
        ])
        try Item.validate(name: params.name)

        let repository = repositoryFactory(context)
        guard let item = try await repository.fetch(byId: params.itemId) else {
            throw ApplicationError.notFound(entity: "Item", id: params.itemId)
        }

        // If the client supplied an If-Match precondition, pin it as the expected
        // token: the check-and-set then fails (ConcurrencyError) unless it equals
        // the currently stored version. Without one, the loaded token is used and
        // the transaction's serializability guards internal conflicts.
        if let expected = params.expectedEntityVersion {
            item.version = expected
        }

        item.update(name: params.name, description: params.description)
        try await repository.update(entity: item)

        return mapper.toDTO(entity: item)
    }
}
