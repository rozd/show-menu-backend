import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

@Suite("UserOnboardUseCase")
struct UserOnboardUseCaseTests {
    let mapper = UserMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT() -> (
        ds: InMemoryDataSource<UserModel>,
        collector: InMemoryDomainEventCollector,
        context: StubUnitOfWorkContext
    ) {
        let ds = InMemoryDataSource<UserModel>(id: { $0.id })
        let collector = InMemoryDomainEventCollector()
        let ctx = StubUnitOfWorkContext(transaction: "stub", collector: collector)
        return (ds, collector, ctx)
    }

    private func makeRepoFactory(
        ds: InMemoryDataSource<UserModel>
    ) -> RepositoryFactory<any UserRepository> {
        let mapper = self.mapper
        return { ctx in
            FirestoreUserRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
    }

    @Test("happy path inserts user and records created event")
    func onboard_happyPath() async throws {
        let (ds, collector, ctx) = makeSUT()
        let useCase = UserOnboardUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            logger: makeLogger()
        )

        try await useCase.execute(params: .init(
            userId: User.Id(rawValue: "u-1"),
            email: "alice@example.com",
            displayName: "Alice"
        ))

        let inserted = await ds.insertedModels
        #expect(inserted.count == 1)
        #expect(inserted.first?.id == "u-1")
        #expect(inserted.first?.email == "alice@example.com")
        #expect(inserted.first?.displayName == "Alice")

        let events = await collector.drain()
        #expect(events.count == 1)
        let event = try #require(events.first as? UserEvent)
        #expect(event.kind == .created)
        #expect(event.aggregateId == User.Id(rawValue: "u-1"))
    }

    @Test("idempotent: existing user is not re-inserted")
    func onboard_idempotent() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-existing", email: "existing@example.com"))

        let useCase = UserOnboardUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            logger: makeLogger()
        )

        try await useCase.execute(params: .init(
            userId: User.Id(rawValue: "u-existing"),
            email: "different@example.com",
            displayName: "Different"
        ))

        let inserted = await ds.insertedModels
        #expect(inserted.isEmpty)

        let events = await collector.drain()
        #expect(events.isEmpty)
    }

    @Test("empty userId throws emptyId")
    func onboard_emptyIdThrows() async {
        let (ds, _, ctx) = makeSUT()
        let useCase = UserOnboardUseCase(
            context: ctx,
            repositoryFactory: makeRepoFactory(ds: ds),
            logger: makeLogger()
        )

        await #expect(throws: User.Error.self) {
            try await useCase.execute(params: .init(
                userId: User.Id(rawValue: ""),
                email: nil,
                displayName: nil
            ))
        }
    }
}
