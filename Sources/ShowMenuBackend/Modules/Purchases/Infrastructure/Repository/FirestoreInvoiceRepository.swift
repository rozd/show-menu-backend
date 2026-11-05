import FirestoreAPI

struct FirestoreInvoiceRepository: InvoiceRepository {
    typealias Entity = Invoice
    typealias Model = InvoiceModel

    let mapper: any Mapper<Invoice, InvoiceModel, InvoiceDTO>
    let dataSourceFactory: DataSourceFactory<InvoiceModel>
    let context: any UnitOfWorkContext

    var dataSource: any DataSource<InvoiceModel> {
        dataSourceFactory("", context.transaction)
    }

    func fetch(byId id: Invoice.Id) async throws -> Invoice? {
        guard let model = try await dataSource.fetch(byId: id.description) else {
            return nil
        }
        return try mapper.toEntity(model: model)
    }

    func doInsert(entities: [Invoice]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            if entity.version == .none {
                entity.version = Version(1)
            }
            try await dataSource.insert(model: mapper.toModel(entity: entity))
        }
    }

    func doUpdate(entities: [Invoice]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            entity.version = try await dataSource.update(
                model: mapper.toModel(entity: entity),
                ifMatching: entity.version
            )
        }
    }

    func doDelete(entities: [Invoice]) async throws {
        let dataSource = self.dataSource
        for entity in entities {
            try await dataSource.delete(byId: entity.id.description, ifMatching: entity.version)
        }
    }
}
