import FirestoreAPI

struct FirestoreSubscriptionRepository: SubscriptionRepository {
    typealias Entity = Subscription
    typealias Model = SubscriptionModel

    let mapper: any Mapper<Subscription, SubscriptionModel, SubscriptionDTO>
    let dataSourceFactory: DataSourceFactory<SubscriptionModel>
    let context: any UnitOfWorkContext
    /// A non-transactional transport, for the legacy lookup query (the client cannot query
    /// inside a transaction).
    let directTransaction: @Sendable () -> any Sendable

    /// Subscriptions are a sub-collection of the account: `accounts/{accountId}/subscriptions`.
    private func dataSource(accountId: String) -> any DataSource<SubscriptionModel> {
        dataSourceFactory("accounts/\(accountId)", context.transaction)
    }

    func fetch(byId id: Subscription.Id) async throws -> Subscription? {
        throw ApplicationError.invalidInput(
            reason: "Subscriptions are stored per account; use fetch(accountId:id:)"
        )
    }

    func fetch(accountId: String, id: Subscription.Id) async throws -> Subscription? {
        guard let model = try await dataSource(accountId: accountId).fetch(byId: id.rawValue) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func find(accountId: String, orderId: String) async throws -> Subscription? {
        if let found = try await fetch(accountId: accountId, id: .derive(orderId: orderId)) {
            return found
        }
        // Legacy `sub:<random uuid>` documents (created by the Node functions).
        let result = try await dataSourceFactory("accounts/\(accountId)", directTransaction()).query(DataSourceQuery(
            filters: [DataSourceFilter(field: "orderId", op: .equal, value: orderId)],
            limit: 1
        ))
        guard let model = result.items.first else { return nil }
        // Read it again through the transaction, so its snapshot is the one the CAS write checks.
        return try await fetch(accountId: accountId, id: .init(rawValue: model.id))
    }

    func doInsert(entities: [Subscription]) async throws {
        for entity in entities {
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource(accountId: entity.accountId).insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Subscription]) async throws {
        for entity in entities {
            entity.version = try await dataSource(accountId: entity.accountId).update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Subscription]) async throws {
        for entity in entities {
            try await dataSource(accountId: entity.accountId).delete(
                byId: entity.id.rawValue, ifMatching: entity.version
            )
        }
    }
}
