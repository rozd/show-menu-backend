import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

@Suite("UserCreatedIntegrationEventHandler")
struct UserCreatedIntegrationEventHandlerTests {
    let mapper = UserMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT() -> (
        ds: InMemoryDataSource<UserModel>,
        uow: StubUnitOfWork,
        handler: UserCreatedIntegrationEventHandler
    ) {
        let ds = InMemoryDataSource<UserModel>(id: { $0.id })
        let uow = StubUnitOfWork()
        let logger = makeLogger()
        let mapper = self.mapper
        let repoFactory: RepositoryFactory<any UserRepository> = { ctx in
            FirestoreUserRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
        let useCaseFactory: UseCaseFactory<UserOnboardUseCase> = { ctx in
            UserOnboardUseCase(
                context: ctx,
                repositoryFactory: repoFactory,
                logger: logger
            )
        }
        let commandHandler = CreateUserAccountCommandHandler(
            unitOfWork: uow,
            useCaseFactory: useCaseFactory,
            inbox: InboxComponents(storeFactory: { _ in StubInboxStore() }),
            logger: logger
        )
        let handler = UserCreatedIntegrationEventHandler(
            commandHandler: commandHandler,
            logger: logger
        )
        return (ds, uow, handler)
    }

    @Test("dispatching the event onboards a new user")
    func handle_createsUser() async throws {
        let (ds, uow, handler) = makeSUT()

        let event = UserCreatedIntegrationEvent(
            userId: "u-event-1",
            email: "alice@example.com",
            displayName: "Alice"
        )

        try await handler.handle(event)

        let inserted = await ds.insertedModels
        #expect(inserted.count == 1)
        #expect(inserted.first?.id == "u-event-1")
        #expect(inserted.first?.email == "alice@example.com")

        let dispatched = uow.dispatchedEvents
        #expect(dispatched.count == 1)
        let domainEvent = try #require(dispatched.first as? UserEvent)
        #expect(domainEvent.kind == .created)
    }

    @Test("dispatching for existing user is a no-op")
    func handle_idempotent() async throws {
        let (ds, uow, handler) = makeSUT()
        await ds.seed(UserModel(id: "u-existing", email: "existing@example.com"))

        let event = UserCreatedIntegrationEvent(
            userId: "u-existing",
            email: "existing@example.com",
            displayName: "Existing"
        )

        try await handler.handle(event)

        let inserted = await ds.insertedModels
        #expect(inserted.isEmpty)
        #expect(uow.dispatchedEvents.isEmpty)
    }
}
