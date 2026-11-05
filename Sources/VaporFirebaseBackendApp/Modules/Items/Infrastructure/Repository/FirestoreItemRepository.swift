struct FirestoreItemRepository: ItemRepository {
    typealias Entity = Item
    typealias Model = ItemModel

    let mapper: any Mapper<Item, ItemModel, ItemDTO>
    let dataSourceFactory: DataSourceFactory<ItemModel>
    let context: any UnitOfWorkContext

    var dataSource: any DataSource<ItemModel> {
        dataSourceFactory("", context.transaction)
    }

    func fetch(byId id: Item.Id) async throws -> Item? {
        guard let model = try await dataSource.fetch(byId: id.description) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func doInsert(entities: [Item]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            // Establish the initial token so a freshly created aggregate already
            // advertises a version (e.g. as an ETag on the create response).
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource.insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Item]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            // Check-and-set against the token the aggregate was loaded with;
            // advance the in-process token to the persisted value on success.
            entity.version = try await dataSource.update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Item]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            try await dataSource.delete(byId: entity.id.description, ifMatching: entity.version)
        }
    }
}
