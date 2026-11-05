import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

@Suite("ListItemsQueryHandler")
struct ListItemsQueryHandlerTests {

    @Test("maps page, total, and echoes limit/offset")
    func pageAndTotal() async throws {
        let ds = InMemoryDataSource<ItemModel>(id: { $0.id })
        await ds.seed((1...5).map {
            ItemModel(id: "i\($0)", name: "N\($0)", description: nil, version: 1, createdAt: nil, updatedAt: nil)
        })
        let handler = ListItemsQueryHandler(
            dataSourceFactory: { _, _ in ds }, transaction: .stub, mapper: ItemMapper(),
            logger: Logger(label: "test", factory: { _ in CapturingLogHandler() })
        )

        let page = try await handler.handle(ListItemsQuery(pagination: OffsetPagination(offset: 1, limit: 2)))

        #expect(page.total == 5)
        #expect(page.limit == 2)
        #expect(page.offset == 1)
        #expect(page.items.map(\.id) == ["i2", "i3"])

        let q = try #require(await ds.queries.last)
        #expect(q.limit == 2)
        #expect(q.offset == 1)
        #expect(q.orders.count == 1)
        #expect(q.orders.first?.field == "createdAt")
        #expect(q.orders.first?.direction == .descending)
        #expect(q.filters.isEmpty)
    }
}
