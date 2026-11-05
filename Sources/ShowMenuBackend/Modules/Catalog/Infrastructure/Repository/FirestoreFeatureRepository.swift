struct FirestoreFeatureRepository: FeatureRepository {
    typealias Entity = Feature
    typealias Model = FeatureModel

    let mapper: any Mapper<Feature, FeatureModel, FeatureDTO>
    let dataSourceFactory: DataSourceFactory<FeatureModel>
    let context: any UnitOfWorkContext

    var dataSource: any DataSource<FeatureModel> {
        dataSourceFactory("", context.transaction)
    }

    func fetch(byId id: Feature.Id) async throws -> Feature? {
        guard let model = try await dataSource.fetch(byId: id.description) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func doInsert(entities: [Feature]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource.insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Feature]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            entity.version = try await dataSource.update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Feature]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            try await dataSource.delete(byId: entity.id.description, ifMatching: entity.version)
        }
    }
}
