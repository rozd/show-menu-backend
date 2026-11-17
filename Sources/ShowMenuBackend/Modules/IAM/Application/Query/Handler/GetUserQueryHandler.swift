import Foundation
import Logging

struct GetUserQueryHandler: QueryHandler {
    typealias Params = GetUserQuery
    typealias Result = UserDTO?

    let dataSourceFactory: DataSourceFactory<UserModel>
    /// The non-transactional store handle, passed straight through to the
    /// data-source factory. Type-erased on purpose: which adapter is active is the
    /// composition root's business, not the Application layer's.
    let transaction: any Sendable
    let mapper: any Mapper<User, UserModel, UserDTO>
    let logger: Logger

    func handle(_ query: GetUserQuery) async throws -> UserDTO? {
        logger.debug("Handling GetUserQuery", metadata: ["id": .string(query.userId)])
        let dataSource = dataSourceFactory("", transaction)
        guard let model = try await dataSource.fetch(byId: query.userId) else {
            logger.trace("GetUserQuery result", metadata: ["found": .string("false")])
            return nil
        }
        logger.trace("GetUserQuery result", metadata: ["found": .string("true")])
        return mapper.toDTO(model: model)
    }
}
