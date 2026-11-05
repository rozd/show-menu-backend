import Foundation
import Logging

struct FindUserQueryHandler: QueryHandler {
    typealias Params = FindUserQuery
    typealias Result = [UserDTO]

    let dataSourceFactory: DataSourceFactory<UserModel>
    let transaction: FirestoreTransaction
    let mapper: any Mapper<User, UserModel, UserDTO>
    let logger: Logger

    func handle(_ query: FindUserQuery) async throws -> [UserDTO] {
        logger.debug("Handling FindUserQuery", metadata: [
            "displayName": .string(query.displayName ?? "nil"),
            "email": .string(query.email ?? "nil")
        ])
        let dataSource = dataSourceFactory("", transaction)

        var filters: [DataSourceFilter] = []
        if let displayName = query.displayName {
            filters.append(DataSourceFilter(field: "displayName", op: .equal, value: displayName))
        }
        if let email = query.email {
            filters.append(DataSourceFilter(field: "email", op: .equal, value: email))
        }

        let result = try await dataSource.query(DataSourceQuery(filters: filters))
        let dtos = result.items.map { mapper.toDTO(model: $0) }
        logger.trace("FindUserQuery result", metadata: ["count": .string(String(dtos.count))])
        return dtos
    }
}
