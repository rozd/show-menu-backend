import Foundation
import Logging

struct ListPlansQueryHandler: QueryHandler {
    typealias Params = ListPlansQuery
    typealias Result = [PlanDTO]

    let dataSourceFactory: DataSourceFactory<PlanModel>
    let transaction: FirestoreTransaction
    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let logger: Logger

    /// All plans, oldest first (then by id) so the order is deterministic.
    func handle(_ query: ListPlansQuery) async throws -> [PlanDTO] {
        logger.debug("Handling ListPlansQuery")
        let result = try await dataSourceFactory("", transaction).query(DataSourceQuery())
        return result.items
            .sorted { ($0.createdAt.asDate, $0.id) < ($1.createdAt.asDate, $1.id) }
            .map { mapper.toDTO(model: $0) }
    }
}
