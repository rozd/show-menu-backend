import FirestoreAPI

struct FirestoreOrderRepository: OrderRepository {
    typealias Entity = Order
    typealias Model = OrderModel

    let mapper: any Mapper<Order, OrderModel, OrderDTO>
    let dataSourceFactory: DataSourceFactory<OrderModel>
    let context: any UnitOfWorkContext

    /// Orders are a sub-collection of the account: `accounts/{accountId}/orders`.
    private func dataSource(accountId: String) -> any DataSource<OrderModel> {
        dataSourceFactory("accounts/\(accountId)", context.transaction)
    }

    func fetch(byId id: Order.ID) async throws -> Order? {
        throw ApplicationError.invalidInput(
            reason: "Orders are stored per account; use fetch(accountId:id:)"
        )
    }

    func fetch(accountId: String, id: Order.Id) async throws -> Order? {
        guard let model = try await dataSource(accountId: accountId).fetch(byId: id.description) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func doInsert(entities: [Order]) async throws {
        for entity in entities {
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource(accountId: entity.accountId).insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Order]) async throws {
        for entity in entities {
            entity.version = try await dataSource(accountId: entity.accountId).update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Order]) async throws {
        for entity in entities {
            try await dataSource(accountId: entity.accountId).delete(
                byId: entity.id.description, ifMatching: entity.version
            )
        }
    }
}
