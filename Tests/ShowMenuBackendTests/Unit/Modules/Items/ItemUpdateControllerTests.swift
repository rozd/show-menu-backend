import Foundation
import Testing
import Logging
import Vapor
@testable import ShowMenuBackend

/// HTTP-edge tests for the ETag / If-Match layer on `PUT /api/v1/items/:id`,
/// driving the real `ItemController` against an in-memory versioned store.
@Suite("Item Update — ETag / If-Match")
struct ItemUpdateControllerTests {

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeController(ds: InMemoryVersionedDataSource<ItemModel>) -> ItemController {
        let mapper = ItemMapper()
        let logger = makeLogger()
        let repoFactory: RepositoryFactory<any ItemRepository> = { ctx in
            FirestoreItemRepository(mapper: mapper, dataSourceFactory: { _, _ in ds }, context: ctx)
        }
        let getHandler = GetItemQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger
        )
        let listHandler = ListItemsQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: mapper, logger: logger
        )
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

    private func makeRequest(app: Application, ifMatch: String?) -> Request {
        var body = ByteBufferAllocator().buffer(capacity: 64)
        body.writeString(#"{"name":"Updated","description":"d"}"#)
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        if let ifMatch { headers.replaceOrAdd(name: .ifMatch, value: ifMatch) }
        let req = Request(
            application: app, method: .PUT, url: "/api/v1/items/i1",
            headers: headers, collectedBody: body, on: app.eventLoopGroup.any()
        )
        req.parameters.set("itemId", to: "i1")
        return req
    }

    private func seeded(version: Int) async -> InMemoryVersionedDataSource<ItemModel> {
        let ds = InMemoryVersionedDataSource<ItemModel>(id: { $0.id })
        await ds.seed(ItemModel(id: "i1", name: "Original", description: nil,
                                version: version, createdAt: nil, updatedAt: nil))
        return ds
    }

    @Test("stale If-Match returns 412 Precondition Failed and does not write")
    func staleIfMatchReturns412() async throws {
        let app = try await Application.make(.testing)
        let ds = await seeded(version: 2)
        let controller = makeController(ds: ds)
        let req = makeRequest(app: app, ifMatch: "\"1\"") // stale: stored is 2

        do {
            _ = try await controller.updateItem(req: req)
            Issue.record("Expected updateItem to throw 412")
        } catch let abort as any AbortError {
            #expect(abort.status == .preconditionFailed)
        }

        let stored = await ds.current("i1")
        #expect(stored?.version == 2)
        #expect(stored?.name == "Original")

        try await app.asyncShutdown()
    }

    @Test("matching If-Match succeeds, advances version, and returns new ETag")
    func matchingIfMatchSucceeds() async throws {
        let app = try await Application.make(.testing)
        let ds = await seeded(version: 2)
        let controller = makeController(ds: ds)
        let req = makeRequest(app: app, ifMatch: "\"2\"") // matches stored

        let response = try await controller.updateItem(req: req)

        #expect(response.status == .ok)
        #expect(response.headers.first(name: .eTag) == "\"3\"")
        let stored = await ds.current("i1")
        #expect(stored?.version == 3)
        #expect(stored?.name == "Updated")

        try await app.asyncShutdown()
    }

    @Test("update without If-Match succeeds and advances version")
    func noIfMatchSucceeds() async throws {
        let app = try await Application.make(.testing)
        let ds = await seeded(version: 2)
        let controller = makeController(ds: ds)
        let req = makeRequest(app: app, ifMatch: nil)

        let response = try await controller.updateItem(req: req)

        #expect(response.status == .ok)
        #expect(response.headers.first(name: .eTag) == "\"3\"")
        #expect(await ds.current("i1")?.version == 3)

        try await app.asyncShutdown()
    }
}
