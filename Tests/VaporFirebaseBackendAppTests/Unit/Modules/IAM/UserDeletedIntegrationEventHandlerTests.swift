import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

@Suite("UserDeletedIntegrationEventHandler")
struct UserDeletedIntegrationEventHandlerTests {
    let mapper = UserMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT() -> (
        ds: InMemoryDataSource<UserModel>,
        uow: StubUnitOfWork,
        handler: UserDeletedIntegrationEventHandler
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
        let useCaseFactory: UseCaseFactory<UserRemoveUseCase> = { ctx in
            UserRemoveUseCase(
                context: ctx,
                repositoryFactory: repoFactory,
                ability: RemoveUserAbility(),
                logger: logger
            )
        }
        let commandHandler = DeleteUserAccountCommandHandler(
            unitOfWork: uow,
            useCaseFactory: useCaseFactory,
            inbox: InboxComponents(storeFactory: { _ in StubInboxStore() }),
            logger: logger
        )
        let handler = UserDeletedIntegrationEventHandler(
            commandHandler: commandHandler,
            logger: logger
        )
        return (ds, uow, handler)
    }

    @Test("dispatching the event removes the user")
    func handle_removesUser() async throws {
        let (ds, uow, handler) = makeSUT()
        await ds.seed(UserModel(id: "u-1", email: "alice@example.com"))

        let event = UserDeletedIntegrationEvent(
            userId: "u-1",
            email: "alice@example.com",
            displayName: "Alice"
        )

        try await handler.handle(event)

        let deleted = await ds.deletedIds
        #expect(deleted == ["u-1"])

        let dispatched = uow.dispatchedEvents
        #expect(dispatched.count == 1)
        let domainEvent = try #require(dispatched.first as? UserEvent)
        #expect(domainEvent.kind == .deleted)
    }

    @Test("dispatching for missing user is a no-op")
    func handle_idempotent() async throws {
        let (ds, uow, handler) = makeSUT()

        let event = UserDeletedIntegrationEvent(
            userId: "u-missing",
            email: nil,
            displayName: nil
        )

        try await handler.handle(event)

        let deleted = await ds.deletedIds
        #expect(deleted.isEmpty)
        #expect(uow.dispatchedEvents.isEmpty)
    }
}
