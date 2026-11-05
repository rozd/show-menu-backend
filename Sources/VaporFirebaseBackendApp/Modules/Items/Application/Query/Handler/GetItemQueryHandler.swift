import Foundation
import Logging

struct GetItemQueryHandler: QueryHandler {
    typealias Params = GetItemQuery
    typealias Result = ItemDTO?

    let dataSourceFactory: DataSourceFactory<ItemModel>
    let transaction: FirestoreTransaction
    let mapper: any Mapper<Item, ItemModel, ItemDTO>
    let logger: Logger

    func handle(_ query: GetItemQuery) async throws -> ItemDTO? {
        logger.debug("Handling GetItemQuery", metadata: ["id": .string(query.itemId)])
        let dataSource = dataSourceFactory("", transaction)
        guard let model = try await dataSource.fetch(byId: query.itemId) else {
            logger.trace("GetItemQuery result", metadata: ["found": .string("false")])
            return nil
        }
        logger.trace("GetItemQuery result", metadata: ["found": .string("true")])
        return mapper.toDTO(model: model)
    }
}
