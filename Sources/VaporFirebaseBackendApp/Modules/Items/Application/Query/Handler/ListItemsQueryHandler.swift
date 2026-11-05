import Foundation
import Logging

/// Answers ``ListItemsQuery`` with an ``ItemPageDTO``.
///
/// Ordering is on `createdAt` only: Firestore implicitly appends `__name__` as a
/// stable tiebreak, and the single-field index is automatic, so no composite
/// index is needed. The page and the total are two separate reads and are not
/// atomic with each other.
struct ListItemsQueryHandler: QueryHandler {
    typealias Params = ListItemsQuery
    typealias Result = ItemPageDTO

    let dataSourceFactory: DataSourceFactory<ItemModel>
    let transaction: FirestoreTransaction
    let mapper: any Mapper<Item, ItemModel, ItemDTO>
    let logger: Logger

    func handle(_ query: ListItemsQuery) async throws -> ItemPageDTO {
        logger.debug("Handling ListItemsQuery")
        let dataSource = dataSourceFactory("", transaction)
        let pagination = query.pagination
        let pageQuery = DataSourceQuery(
            orders: [DataSourceOrder(field: "createdAt", direction: .descending)],
            limit: pagination.limit,
            offset: pagination.offset
        )
        async let page = dataSource.query(pageQuery)
        async let total = dataSource.countAll()
        let (result, count) = try await (page, total)
        let dtos = result.items.map { mapper.toDTO(model: $0) }
        logger.trace("ListItemsQuery result", metadata: [
            "count": .string(String(dtos.count)),
            "total": .string(String(count))
        ])
        return ItemPageDTO(items: dtos, total: count, limit: pagination.limit, offset: pagination.offset)
    }
}
