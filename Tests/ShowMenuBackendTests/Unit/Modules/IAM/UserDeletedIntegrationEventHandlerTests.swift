import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

@Suite("UserDeletedIntegrationEventHandler")
struct UserDeletedIntegrationEventHandlerTests {
    let mapper = UserMapper()

    private func makeLogger() -> Logger {
        Logger(label: "test", factory: { _ in CapturingLogHandler() })
    }

    private func makeSUT(inbox: StubInboxStore = StubInboxStore()) -> (
        ds: SpyDataSource<UserModel>,
        uow: StubUnitOfWork,
        handler: UserDeletedIntegrationEventHandler
    ) {
        let ds = SpyDataSource<UserModel>(id: { $0.id })
        let uow = StubUnitOfWork()
        let logger = makeLogger()
        let mapper = self.mapper
        let repoFactory: RepositoryFactory<any UserRepository> = { ctx in
            DefaultUserRepository(
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
            inbox: InboxComponents(
                storeFactory: { _ in inbox },
                configuration: InboxConfiguration.default
            ),
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

    @Test("same event id delivered twice results in one delete")
    func handle_inboxDeduplication() async throws {
        let inbox = StubInboxStore()
        let (ds, _, handler) = makeSUT(inbox: inbox)
        await ds.seed(UserModel(id: "u-dedup-1", email: "dedup@example.com"))

        let eventId = UUID()
        let event = UserDeletedIntegrationEvent(
            userId: "u-dedup-1",
            email: "dedup@example.com",
            displayName: "Dedup"
        )

        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await handler.handle(event)
        }
        try await RequestContext.$integrationEventId.withValue(eventId) {
            try await handler.handle(event)
        }

        let deleted = await ds.deletedIds
        #expect(deleted.count == 1, "Same event id should only delete once")
        #expect(await inbox.count == 1, "Inbox should have one processed record")
    }
}
