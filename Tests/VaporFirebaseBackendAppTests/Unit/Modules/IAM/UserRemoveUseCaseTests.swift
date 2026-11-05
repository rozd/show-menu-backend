import Foundation
import Testing
import Logging
@testable import VaporFirebaseBackendApp

@Suite("UserRemoveUseCase")
struct UserRemoveUseCaseTests {
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

    private func makeUseCase(
        ds: InMemoryDataSource<UserModel>,
        ctx: StubUnitOfWorkContext
    ) -> UserRemoveUseCase {
        let mapper = self.mapper
        let repositoryFactory: RepositoryFactory<any UserRepository> = { ctx in
            FirestoreUserRepository(
                mapper: mapper,
                dataSourceFactory: { _, _ in ds },
                context: ctx
            )
        }
        return UserRemoveUseCase(
            context: ctx,
            repositoryFactory: repositoryFactory,
            ability: RemoveUserAbility(),
            logger: makeLogger()
        )
    }

    // MARK: - Happy paths

    @Test("admin removes existing user and records deleted event")
    func remove_asAdmin_happyPath() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-1", email: "alice@example.com"))
        let useCase = makeUseCase(ds: ds, ctx: ctx)
        let admin = StubPrincipal(id: "admin-1", roles: [.admin])

        try await RequestContext.$principal.withValue(admin) {
            try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-1")))
        }

        let deleted = await ds.deletedIds
        #expect(deleted == ["u-1"])

        let events = await collector.drain()
        #expect(events.count == 1)
        let event = try #require(events.first as? UserEvent)
        #expect(event.kind == .deleted)
        #expect(event.aggregateId == User.Id(rawValue: "u-1"))
    }

    @Test("owner removes their own active account")
    func remove_self_activeAccount() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-1", disabled: false))
        let useCase = makeUseCase(ds: ds, ctx: ctx)
        let owner = StubPrincipal(id: "u-1")

        try await RequestContext.$principal.withValue(owner) {
            try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-1")))
        }

        let deleted = await ds.deletedIds
        #expect(deleted == ["u-1"])
        #expect(await collector.drain().count == 1)
    }

    @Test("idempotent: missing user is a no-op before authorization")
    func remove_idempotent() async throws {
        let (ds, collector, ctx) = makeSUT()
        let useCase = makeUseCase(ds: ds, ctx: ctx)
        let admin = StubPrincipal(id: "admin-1", roles: [.admin])

        try await RequestContext.$principal.withValue(admin) {
            try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-missing")))
        }

        #expect(await ds.deletedIds.isEmpty)
        #expect(await collector.drain().isEmpty)
    }

    // MARK: - Policy Enforcement Point (denials)

    @Test("owner may NOT remove their own disabled account")
    func remove_self_disabledAccount_denied() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-1", disabled: true))
        let useCase = makeUseCase(ds: ds, ctx: ctx)
        let owner = StubPrincipal(id: "u-1")

        await #expect(throws: AuthorizationError.denied(
            reason: "A disabled account can only be removed by an administrator"
        )) {
            try await RequestContext.$principal.withValue(owner) {
                try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-1")))
            }
        }

        #expect(await ds.deletedIds.isEmpty)
        #expect(await collector.drain().isEmpty)
    }

    @Test("a non-admin may not remove someone else's account (default deny)")
    func remove_otherUser_denied() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-1"))
        let useCase = makeUseCase(ds: ds, ctx: ctx)
        let stranger = StubPrincipal(id: "u-9")

        await #expect(throws: AuthorizationError.denied(reason: "Not authorized")) {
            try await RequestContext.$principal.withValue(stranger) {
                try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-1")))
            }
        }

        #expect(await ds.deletedIds.isEmpty)
        #expect(await collector.drain().isEmpty)
    }

    @Test("fails closed when no principal is present")
    func remove_noPrincipal_failsClosed() async throws {
        let (ds, collector, ctx) = makeSUT()
        await ds.seed(UserModel(id: "u-1"))
        let useCase = makeUseCase(ds: ds, ctx: ctx)

        await #expect(throws: AuthorizationError.missingPrincipal) {
            try await useCase.execute(params: .init(userId: User.Id(rawValue: "u-1")))
        }

        #expect(await ds.deletedIds.isEmpty)
        #expect(await collector.drain().isEmpty)
    }
}
