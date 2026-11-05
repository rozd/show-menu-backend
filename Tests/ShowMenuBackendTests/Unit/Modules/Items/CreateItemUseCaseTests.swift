import Foundation
import Testing
import Logging
import FirestoreAPI
@testable import ShowMenuBackend

@Suite("Item Use Cases")
struct CreateItemUseCaseTests {
    let mapper = ItemMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT() -> (
        ds: InMemoryDataSource<ItemModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = InMemoryDataSource<ItemModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        let ctx = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        return (ds, collector, ctx)
    }

    private func makeRepoFactory(
        ds: InMemoryDataSource<ItemModel>
    ) -> RepositoryFactory<any ItemRepository> {
        let mapper = self.mapper
        return { ctx in
            FirestoreItemRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
    }

    // MARK: - Create

    @Test("createItem happy path returns DTO and records created event")
    func createItem_happyPath() async throws {
        let (ds, collector, ctx) = makeSUT()
        let useCase = CreateItemUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            mapper: mapper,
            logger: makeLogger()
        )

        let dto = try await useCase.execute(params: .init(
            name: "Widget",
            description: "A sample widget item"
        ))

        #expect(dto.name == "Widget")
        #expect(dto.description == "A sample widget item")
        #expect(!dto.id.isEmpty)

        let inserted = await ds.insertedModels
        #expect(inserted.count == 1)
        #expect(inserted.first?.name == "Widget")

        let events = await collector.drain()
        #expect(events.count == 1)
        let event = try #require(events.first as? ItemEvent)
        #expect(event.kind == .created)
    }

    @Test("createItem with empty name throws emptyName")
    func createItem_emptyNameThrows() async {
        let (ds, _, ctx) = makeSUT()
        let useCase = CreateItemUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            mapper: mapper,
            logger: makeLogger()
        )

        await #expect(throws: Item.Error.self) {
            try await useCase.execute(params: .init(name: "", description: nil))
        }
    }

    @Test("createItem with nil description succeeds")
    func createItem_nilDescriptionIsValid() async throws {
        let (ds, _, ctx) = makeSUT()
        let useCase = CreateItemUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            mapper: mapper,
            logger: makeLogger()
        )

        let dto = try await useCase.execute(params: .init(
            name: "Gadget",
            description: nil
        ))

        #expect(dto.name == "Gadget")
        #expect(dto.description == nil)
    }
}
