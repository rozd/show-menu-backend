import Fluent
import Vapor

typealias UseCaseFactory<T> = @Sendable (_ ctx: any UnitOfWorkContext) -> T

typealias RepositoryFactory<T> = @Sendable (_ ctx: any UnitOfWorkContext) -> T

typealias PrefixedRepositoryFactory<T> = @Sendable (_ prefix: String, _ ctx: any UnitOfWorkContext) -> T

typealias DataSourceFactory<T> = @Sendable (_ prefix: String, _ transaction: any Sendable) -> any QueryableDataSource<T>

extension Application {

    // MARK: - Dependencies

    protocol Dependencies: Sendable {

        // Transport

        var client: any Client { get }

        // DDD

        var integrationEventRegistry: IntegrationEventRegistry { get }

        var integrationEventDispatcher: any IntegrationEventDispatcher { get }

        var integrationEventChannel: any IntegrationEventChannel { get }

        var domainEventDispatcher: any DomainEventDispatcher { get }

        /// Transactional-outbox configuration (collection, batch size, retention,
        /// retry policy, coder), shared by the in-transaction recording side and
        /// the relay side so they agree on the store.
        var outbox: Outbox { get }

        /// The outbox relay: drains pending rows and publishes them through
        /// `integrationEventChannel`. Scheduled by `App/Outbox+Vapor.swift`.
        var outboxRelay: OutboxRelay { get }

        var unitOfWork: any UnitOfWork { get }

        // Idempotency (cross-cutting)

        var idempotencyConfiguration: IdempotencyConfiguration { get }

        var idempotencyStoreFactory: IdempotencyStoreFactory { get }

        // Inbox (consumer-side de-duplication)

        var inboxConfiguration: InboxConfiguration { get }

        var inboxStoreFactory: InboxStoreFactory { get }

        // Store

        /// The SQL database backing every repository, query handler, the outbox
        /// and the idempotency store. Registered in code by
        /// `configureFluentStore(_:)`, which `configure(_:)` calls (see
        /// `App/Fluent+Vapor.swift`).
        var appDatabase: any Database { get }

        /// The non-transactional store handle query handlers read through, and the
        /// outbox relay drains through. Type-erased so the Application layer names
        /// no adapter type.
        var directTransaction: any Sendable { get }

        // MARK: IAM

        var userMapper: UserMapper { get }
        var userDataSourceFactory: DataSourceFactory<UserModel> { get }
        var userRepositoryFactory: RepositoryFactory<any UserRepository> { get }
        var userOnboardUseCaseFactory: UseCaseFactory<UserOnboardUseCase> { get }
        var userRemoveUseCaseFactory: UseCaseFactory<UserRemoveUseCase> { get }
        var getUserQueryHandler: GetUserQueryHandler { get }
        var findUserQueryHandler: FindUserQueryHandler { get }
        var createUserAccountCommandHandler: CreateUserAccountCommandHandler { get }
        var deleteUserAccountCommandHandler: DeleteUserAccountCommandHandler { get }
        var userCreatedIntegrationEventHandler: UserCreatedIntegrationEventHandler { get }
        var userDeletedIntegrationEventHandler: UserDeletedIntegrationEventHandler { get }
    }

    // MARK: - CompositionRoot

    struct CompositionRoot: Dependencies {

        let app: Application

        let resolver = Resolver()

        init(app: Application) {
            self.app = app
        }

        // Transport

        var client: any Client {
            resolver.resolve(\.client) {
                app.client
            }
        }

        // Store

        /// Resolved once, so the whole process shares a single store handle.
        ///
        /// The database is *registered* by ``configureFluentStore(_:)``, not
        /// here: registration and migrations are boot-time side effects that
        /// cannot happen lazily inside a dependency factory, so this only looks
        /// the finished handle up. An `Application` that never ran it has no
        /// store at all — unit tests either override this dependency or use
        /// doubles, and the `preconditionFailure` says which call is missing
        /// rather than handing back a silently empty database.
        var appDatabase: any Database {
            resolver.resolve(\.appDatabase) {
                guard app.databases.ids().contains(.app) else {
                    preconditionFailure(
                        "No store: call `try await configureFluentStore(app)` (as `configure(_:)` does) before touching `app.deps`."
                    )
                }
                return app.db(.app)
            }
        }

        var directTransaction: any Sendable {
            resolver.resolve(\.directTransaction) {
                FluentTransaction.direct(database: appDatabase)
            }
        }

        // DDD

        var integrationEventRegistry: IntegrationEventRegistry {
            resolver.resolve(\.integrationEventRegistry) {
                IntegrationEventRegistry()
            }
        }

        var integrationEventDispatcher: any IntegrationEventDispatcher {
            resolver.resolve(\.integrationEventDispatcher) {
                InProcessIntegrationEventDispatcher(logger: app.logger)
            }
        }

        var integrationEventChannel: any IntegrationEventChannel {
            resolver.resolve(\.integrationEventChannel) {
                InProcessIntegrationEventChannel(
                    dispatcher: integrationEventDispatcher,
                    logger: app.logger,
                )
            }
        }

        var domainEventDispatcher: any DomainEventDispatcher {
            resolver.resolve(\.domainEventDispatcher) {
                InProcessDomainEventDispatcher(logger: app.logger)
            }
        }

        var outbox: Outbox {
            resolver.resolve(\.outbox) {
                Outbox()
            }
        }

        var outboxRelay: OutboxRelay {
            resolver.resolve(\.outboxRelay) {
                // The relay reads/marks/prunes outside any command transaction,
                // so it binds a *direct* (non-transactional) store, and publishes
                // through the existing integration-event channel.
                let outboxStore = FluentOutboxStore(
                    transaction: .direct(database: appDatabase),
                    table: outbox.collection,
                    logger: app.logger
                )
                return outbox.relay(
                    store: outboxStore,
                    channel: integrationEventChannel,
                    logger: app.logger
                )
            }
        }

        var unitOfWork: any UnitOfWork {
            resolver.resolve(\.unitOfWork) {
                FluentUnitOfWork(
                    database: appDatabase,
                    dispatcher: self.domainEventDispatcher,
                    outbox: outbox,
                    logger: app.logger
                )
            }
        }

        // Idempotency (cross-cutting)

        var idempotencyConfiguration: IdempotencyConfiguration {
            resolver.resolve(\.idempotencyConfiguration) {
                .default
            }
        }

        var idempotencyStoreFactory: IdempotencyStoreFactory {
            resolver.resolve(\.idempotencyStoreFactory) {
                let ttl = idempotencyConfiguration.ttl
                return { [logger = app.logger] ctx in
                    guard let txn = ctx.transaction as? FluentTransaction else {
                        preconditionFailure(
                            "FluentIdempotencyStore requires a FluentTransaction, but received \(type(of: ctx.transaction)); the idempotency store must run inside FluentUnitOfWork."
                        )
                    }
                    return FluentIdempotencyStore(
                        transaction: txn,
                        ttl: ttl,
                        logger: logger
                    )
                }
            }
        }

        // Inbox (consumer-side de-duplication)

        var inboxConfiguration: InboxConfiguration {
            resolver.resolve(\.inboxConfiguration) {
                .default
            }
        }

        var inboxStoreFactory: InboxStoreFactory {
            resolver.resolve(\.inboxStoreFactory) {
                let ttl = inboxConfiguration.ttl
                return { [logger = app.logger] ctx in
                    guard let txn = ctx.transaction as? FluentTransaction else {
                        preconditionFailure(
                            "FluentInboxStore requires a FluentTransaction, but received \(type(of: ctx.transaction)); the inbox store must run inside FluentUnitOfWork."
                        )
                    }
                    return FluentInboxStore(
                        transaction: txn,
                        ttl: ttl,
                        logger: logger
                    )
                }
            }
        }
    }
}

// MARK: - Dependency Resolver

extension Application.CompositionRoot {

    final class Resolver: @unchecked Sendable {

        private let lock = NSRecursiveLock()

        // MARK: Overridden

        private var overridden = Partial<any Application.Dependencies>()

        func override(_ overrides: Partial<any Application.Dependencies>) {
            lock.withLock {
                overridden = overrides
            }
        }

        // MARK: Persistent

        private var persistent: [PartialKeyPath<any Application.Dependencies>: Any] = [:]

        func resolve<T>(
            _ keyPath: KeyPath<any Application.Dependencies, T>,
            factory: () -> T
        ) -> T {
            if let overridden = overridden[keyPath] {
                return overridden
            }

            lock.lock()
            defer { lock.unlock() }

            // `flatMap` before the cast, for the reason spelled out in `Partial`:
            // a marker-protocol `T` (`any Sendable`) makes `as?` unconditional, so
            // an absent entry would "hit" the cache and return a boxed `nil`.
            if let cached = persistent[keyPath].flatMap({ $0 as? T }) {
                return cached
            }

            let instance = factory()
            persistent[keyPath] = instance

            return instance
        }

        // MARK: Reset

        func reset(overrides: Bool = true, persistent: Bool = true) {
            lock.withLock {
                if overrides {
                    self.overridden = Partial<any Application.Dependencies>()
                }
                if persistent {
                    self.persistent = [:]
                }
            }
        }
    }
}

// MARK: - Utils

private extension NSRecursiveLock {
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}

// MARK: - Application Extension

extension Application {
    private struct CompositionRootKey: StorageKey {
        typealias Value = Application.CompositionRoot
    }

    var deps: any Application.Dependencies {
        if let existing = storage[CompositionRootKey.self] {
            return existing
        }
        let root = Application.CompositionRoot(app: self)
        storage[CompositionRootKey.self] = root
        return root
    }
}

// MARK: - Request Extension

extension Request {
    var deps: any Application.Dependencies {
        application.deps
    }
}
