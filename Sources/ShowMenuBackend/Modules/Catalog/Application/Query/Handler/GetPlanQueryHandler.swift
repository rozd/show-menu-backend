import Foundation
import Logging

struct GetPlanQueryHandler: QueryHandler {
    typealias Params = GetPlanQuery
    typealias Result = PlanDTO

    let dataSourceFactory: DataSourceFactory<PlanModel>
    let transaction: FirestoreTransaction
    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let logger: Logger

    /// Throws `ApplicationError.notFound` (404) for an unknown id.
    func handle(_ query: GetPlanQuery) async throws -> PlanDTO {
        logger.debug("Handling GetPlanQuery", metadata: ["id": .string(query.planId)])
        let dataSource = dataSourceFactory("", transaction)
        guard let model = try await dataSource.fetch(byId: query.planId) else {
            throw ApplicationError.notFound(entity: "Plan", id: Plan.Id(rawValue: query.planId))
        }
        return mapper.toDTO(model: model)
    }
}
