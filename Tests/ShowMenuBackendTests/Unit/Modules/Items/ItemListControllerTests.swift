import Foundation
import Testing
import Logging
import Vapor
@testable import ShowMenuBackend

/// Edge clamping of `GET /api/v1/items?limit=&offset=` through the real controller.
@Suite("Item List — paging clamp")
struct ItemListControllerTests {

    private func makeController(ds: InMemoryDataSource<ItemModel>) -> ItemController {
        let mapper = ItemMapper()
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        let ds = ds
        let getHandler = GetItemQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger
        )
        let listHandler = ListItemsQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger
        )
        let repoFactory: RepositoryFactory<any ItemRepository> = { ctx in
            FirestoreItemRepository(mapper: mapper, dataSourceFactory: { _, _ in ds }, context: ctx)
        }
        let createHandler = CreateItemCommandHandler(
            unitOfWork: StubUnitOfWork(),
            useCaseFactory: { ctx in
                CreateItemUseCase(context: ctx, repositoryFactory: repoFactory, mapper: mapper, logger: logger)
            },
            idempotency: IdempotencyComponents(storeFactory: { _ in InMemoryIdempotencyStore() }, configuration: .default),
            logger: logger
        )
        let updateHandler = UpdateItemCommandHandler(
            unitOfWork: StubUnitOfWork(),
            useCaseFactory: { ctx in
                UpdateItemUseCase(context: ctx, repositoryFactory: repoFactory, mapper: mapper, logger: logger)
            },
            idempotency: IdempotencyComponents(storeFactory: { _ in InMemoryIdempotencyStore() }, configuration: .default),
            logger: logger
        )
        return ItemController(
            getItemQueryHandler: getHandler,
            listItemsQueryHandler: listHandler,
            createItemCommandHandler: createHandler,
            updateItemCommandHandler: updateHandler
        )
    }

    @Test("clamps limit/offset", arguments: [
        ("/api/v1/items", 20, 0),
        ("/api/v1/items?limit=0", 1, 0),
        ("/api/v1/items?limit=-3", 1, 0),
        ("/api/v1/items?limit=500", 100, 0),
        ("/api/v1/items?offset=-5", 20, 0),
        ("/api/v1/items?limit=0&offset=-5", 1, 0),
        ("/api/v1/items?limit=7&offset=3", 7, 3),
    ])
    func clamps(url: String, expectedLimit: Int, expectedOffset: Int) async throws {
        let app = try await Application.make(.testing)
        let ds = InMemoryDataSource<ItemModel>(id: { $0.id })
        let controller = makeController(ds: ds)
        let req = Request(application: app, method: .GET, url: URI(string: url), on: app.eventLoopGroup.any())

        let page: ItemPageDTO
        do {
            page = try await controller.listItems(req: req)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()

        #expect(page.limit == expectedLimit)
        #expect(page.offset == expectedOffset)
        let q = try #require(await ds.queries.last)
        #expect(q.limit == expectedLimit)
        #expect(q.offset == expectedOffset)
    }

    @Test("ItemPageDTO encodes items/total/limit/offset keys")
    func pageDTOEncoding() throws {
        let dto = ItemPageDTO(items: [], total: 9, limit: 20, offset: 4)
        let data = try JSONEncoder().encode(dto)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["items", "total", "limit", "offset"])
        #expect(json["total"] as? Int == 9)
        #expect(json["limit"] as? Int == 20)
        #expect(json["offset"] as? Int == 4)
        #expect((json["items"] as? [Any])?.isEmpty == true)
    }
}
