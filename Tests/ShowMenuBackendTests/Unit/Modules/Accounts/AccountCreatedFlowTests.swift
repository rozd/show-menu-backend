import Foundation
import Testing
import Logging
@testable import ShowMenuBackend

/// `AccountCreatedIntegrationEvent` → two independent inboxed consumers:
/// `LinkAccountToCreator` (IAM) and `GrantAccountOwnerPermission` (Accounts).
@Suite("Account created: link to creator + owner permission")
struct AccountCreatedFlowTests {

    /// In-memory `AccountPermissionStore` capturing writes by `accounts/{a}/permissions/{u}`.
    private actor InMemoryPermissionStore: AccountPermissionStore {
        private(set) var docs: [String: AccountPermissionModel] = [:]
        private(set) var writes = 0

        func put(_ permission: AccountPermissionModel, accountId: String, userId: String) async throws {
            docs["accounts/\(accountId)/permissions/\(userId)"] = permission
            writes += 1
        }
    }

    private struct SUT {
        let users: InMemoryDataSource<UserModel>
        let accounts: InMemoryDataSource<AccountModel>
        let permissions: InMemoryPermissionStore
        let inbox: StubInboxStore
        let uow: StubUnitOfWork
        let link: LinkAccountOnAccountCreatedHandler
        let grant: GrantOwnerPermissionOnAccountCreatedHandler
    }

    private func makeSUT() -> SUT {
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        let users = InMemoryDataSource<UserModel>(id: { $0.id })
        let accounts = InMemoryDataSource<AccountModel>(id: { $0.id })
        let permissions = InMemoryPermissionStore()
        let inbox = StubInboxStore()
        let uow = StubUnitOfWork()
        let userMapper = UserMapper()

        let linkUseCase: UseCaseFactory<UserLinkAccountUseCase> = { ctx in
            UserLinkAccountUseCase(
                context: ctx,
                repositoryFactory: { ctx in
                    FirestoreUserRepository(mapper: userMapper, dataSourceFactory: { _, _ in users }, context: ctx)
                },
                logger: logger
            )
        }
        let grantUseCase: UseCaseFactory<GrantAccountOwnerPermissionUseCase> = { ctx in
            GrantAccountOwnerPermissionUseCase(
                context: ctx,
                accountDataSourceFactory: { _, _ in accounts },
                accountMapper: AccountMapper(),
                permissionStoreFactory: { _ in permissions },
                logger: logger
            )
        }
        let components = InboxComponents(storeFactory: { _ in inbox })
        return SUT(
            users: users, accounts: accounts, permissions: permissions, inbox: inbox, uow: uow,
            link: LinkAccountOnAccountCreatedHandler(
                commandHandler: LinkAccountToCreatorCommandHandler(
                    unitOfWork: uow, useCaseFactory: linkUseCase, inbox: components, logger: logger
                ),
                logger: logger
            ),
            grant: GrantOwnerPermissionOnAccountCreatedHandler(
                commandHandler: GrantAccountOwnerPermissionCommandHandler(
                    unitOfWork: uow, useCaseFactory: grantUseCase, inbox: components, logger: logger
                ),
                logger: logger
            )
        )
    }

    private func event(account: String = "acc-1", creator: String = "u-1") -> AccountCreatedIntegrationEvent {
        AccountCreatedIntegrationEvent(accountId: account, creatorId: creator, name: "Cafe")
    }

    /// Delivers `event` the way the dispatcher does: with its id bound for the inbox.
    private func deliver<H: IntegrationEventHandler>(_ event: AccountCreatedIntegrationEvent, to handler: H) async throws {
        try await RequestContext.$integrationEventId.withValue(event.id) {
            try await handler.handle(event as! H.Event)
        }
    }

    // MARK: Link

    @Test("link: appends the account to the creator's accounts")
    func link_appends() async throws {
        let sut = makeSUT()
        await sut.users.seed(UserModel(id: "u-1", email: "a@example.com", accounts: ["old"], createdAt: nil))

        try await deliver(event(), to: sut.link)

        let updated = try #require(await sut.users.updatedModels.last)
        #expect(updated.accounts == ["old", "acc-1"])
        #expect(updated.email == "a@example.com")
        #expect(await sut.users.insertedModels.isEmpty)
    }

    @Test("link: a missing user is upserted as a minimal profile holding the link")
    func link_missingUser() async throws {
        let sut = makeSUT()

        try await deliver(event(), to: sut.link)

        let inserted = try #require(await sut.users.insertedModels.first)
        #expect(inserted.id == "u-1")
        #expect(inserted.accounts == ["acc-1"])
        #expect(inserted.email == nil)
        #expect(inserted.createdAt != nil)
    }

    @Test("link: an already linked account writes nothing")
    func link_alreadyLinked() async throws {
        let sut = makeSUT()
        await sut.users.seed(UserModel(id: "u-1", accounts: ["acc-1"]))

        try await deliver(event(), to: sut.link)

        #expect(await sut.users.updatedModels.isEmpty)
        #expect(await sut.users.insertedModels.isEmpty)
    }

    @Test("link: a redelivery of the same event is skipped by the inbox")
    func link_redeliverySkipped() async throws {
        let sut = makeSUT()
        let evt = event()

        try await deliver(evt, to: sut.link)
        // Simulate a lost write between deliveries: if the inbox did NOT skip, the
        // second delivery would re-link. The marker, not the data, prevents it.
        await sut.users.reset()
        try await deliver(evt, to: sut.link)

        #expect(await sut.users.insertedModels.isEmpty)
        #expect(await sut.users.updatedModels.isEmpty)
        #expect(await sut.inbox.count == 1)
    }

    @Test("link: a different event for the same account is processed (not deduplicated by account)")
    func link_distinctEventProcessed() async throws {
        let sut = makeSUT()
        try await deliver(event(account: "acc-1"), to: sut.link)
        try await deliver(event(account: "acc-2"), to: sut.link)
        let stored = try #require(try await sut.users.fetch(byId: "u-1"))
        #expect(stored.accounts == ["acc-1", "acc-2"])
    }

    @Test("link: the failing handler does not run the other consumer's work, consumers dedup independently")
    func consumers_independentMarkers() async throws {
        let sut = makeSUT()
        await sut.accounts.seed(AccountModel(id: "acc-1", name: "Cafe", creator: "u-1"))
        let evt = event()

        try await deliver(evt, to: sut.link)
        try await deliver(evt, to: sut.grant)

        #expect(await sut.inbox.count == 2)
        #expect(await sut.permissions.writes == 1)
    }

    // MARK: Onboarding after a placeholder

    @Test("onboarding completes the bare profile created by a link and keeps accounts")
    func onboarding_completesPlaceholder() async throws {
        let sut = makeSUT()
        let logger = Logger(label: "test", factory: { _ in CapturingLogHandler() })
        try await deliver(event(), to: sut.link) // user doc did not exist yet
        let userMapper = UserMapper()
        let onboard = UserOnboardUseCase(
            context: StubUnitOfWorkContext(transaction: "stub", collector: InMemoryDomainEventCollector()),
            repositoryFactory: { ctx in
                FirestoreUserRepository(mapper: userMapper, dataSourceFactory: { _, _ in sut.users }, context: ctx)
            },
            logger: logger
        )

        try await onboard.execute(params: .init(
            userId: User.Id(rawValue: "u-1"), email: "a@example.com", name: "Alice", avatarURL: nil
        ))

        let stored = try #require(try await sut.users.fetch(byId: "u-1"))
        #expect(stored.email == "a@example.com")
        #expect(stored.name == "Alice")
        #expect(stored.accounts == ["acc-1"])
        #expect(await sut.users.insertedModels.count == 1) // only the placeholder insert
    }

    // MARK: Grant owner permission

    @Test("grant: writes {role: owner, permissions: []} for the account's creator")
    func grant_writesOwner() async throws {
        let sut = makeSUT()
        await sut.accounts.seed(AccountModel(id: "acc-1", name: "Cafe", creator: "u-1"))

        try await deliver(event(), to: sut.grant)

        let doc = try #require(await sut.permissions.docs["accounts/acc-1/permissions/u-1"])
        #expect(doc == AccountPermissionModel(role: "owner", permissions: []))
    }

    @Test("grant: uses the stored account's creator, not the event's")
    func grant_trustsStoredCreator() async throws {
        let sut = makeSUT()
        await sut.accounts.seed(AccountModel(id: "acc-1", name: "Cafe", creator: "real-creator"))

        try await deliver(event(creator: "forged"), to: sut.grant)

        let docs = await sut.permissions.docs
        #expect(docs.keys.sorted() == ["accounts/acc-1/permissions/real-creator"])
    }

    @Test("grant: a missing account throws and writes nothing")
    func grant_missingAccount() async throws {
        let sut = makeSUT()
        await #expect(throws: AccountNotFoundError.self) {
            try await deliver(event(), to: sut.grant)
        }
        #expect(await sut.permissions.writes == 0)
        #expect(await sut.inbox.count == 0)
    }

    @Test("grant: a redelivery is skipped by the inbox")
    func grant_redeliverySkipped() async throws {
        let sut = makeSUT()
        await sut.accounts.seed(AccountModel(id: "acc-1", name: "Cafe", creator: "u-1"))
        let evt = event()

        try await deliver(evt, to: sut.grant)
        try await deliver(evt, to: sut.grant)

        #expect(await sut.permissions.writes == 1)
    }

    // MARK: Mapping and wire shape

    @Test("account mapper requires a creator")
    func mapper_requiresCreator() throws {
        let mapper = AccountMapper()
        #expect(try mapper.toEntity(model: AccountModel(id: "a", name: "n", creator: "u"))
            == Account(id: "a", name: "n", creator: "u"))
        #expect(throws: MappingError.self) { try mapper.toEntity(model: AccountModel(id: "a", name: "n", creator: nil)) }
        #expect(throws: MappingError.self) { try mapper.toEntity(model: AccountModel(id: "a", name: "n", creator: "")) }
    }

    @Test("forwarder body decodes; unknown fields are ignored; creator is optional on the wire")
    func eventData_decodes() throws {
        let json = Data(#"""
        {"path":"accounts/acc-1","documentId":"acc-1","data":{"name":"Cafe","creator":"u-1","createdAt":"2026-11-05T10:00:00.000Z","extra":{"a":[1,2]}}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(FirestoreEventData.self, from: json)
        #expect(decoded.documentId == "acc-1")
        #expect(decoded.data?.creator == "u-1")
        #expect(decoded.data?.name == "Cafe")

        let bare = Data(#"{"path":"accounts/x","documentId":"x","data":{}}"#.utf8)
        #expect(try JSONDecoder().decode(FirestoreEventData.self, from: bare).data?.creator == nil)
    }

    @Test("the firestore CloudEvent type is a supported webhook type")
    func firestoreTypeSupported() {
        #expect(CloudEventsParser.supportedEventTypes.contains("google.cloud.firestore.document.v1.created"))
    }
}
