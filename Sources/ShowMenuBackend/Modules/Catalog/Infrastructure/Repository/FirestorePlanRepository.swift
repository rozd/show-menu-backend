struct FirestorePlanRepository: PlanRepository {
    typealias Entity = Plan
    typealias Model = PlanModel

    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let dataSourceFactory: DataSourceFactory<PlanModel>
    let context: any UnitOfWorkContext
    /// Transaction handle for the SKU lookup. The pinned FirebaseAPI cannot run a
    /// query *inside* a transaction (its transactional `runQuery` sends an invalid
    /// `parent`), so production passes a `.direct` handle; defaults to the
    /// unit-of-work transaction for other stores/tests.
    var lookupTransaction: (@Sendable () -> any Sendable)? = nil

    var dataSource: any DataSource<PlanModel> {
        dataSourceFactory("", context.transaction)
    }

    func fetch(byId id: Plan.Id) async throws -> Plan? {
        guard let model = try await dataSource.fetch(byId: id.description) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func fetch(bySKU sku: String) async throws -> Plan? {
        let result = try await dataSourceFactory("", lookupTransaction?() ?? context.transaction).query(
            DataSourceQuery(
                filters: [DataSourceFilter(field: "SKU", op: .equal, value: sku)],
                limit: 1
            )
        )
        return try result.items.first.map { try mapper.toEntity(model: $0) }
    }

    func doInsert(entities: [Plan]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource.insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Plan]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            entity.version = try await dataSource.update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Plan]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            try await dataSource.delete(byId: entity.id.description, ifMatching: entity.version)
        }
    }
}
