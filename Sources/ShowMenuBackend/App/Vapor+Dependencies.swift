import FirestoreAPI
import GRPCCore
import GRPCNIOTransportHTTP2
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

        // Inbox (idempotent consumer)

        var inboxConfiguration: InboxConfiguration { get }

        var inboxStoreFactory: InboxStoreFactory { get }

        // GCP

        var config: GoogleCloudPlatform.Configuration { get }

        var authProvider: any GCPAuthProvider { get }

        var firestore: Firestore<HTTP2ClientTransport.Posix> { get }

        // MARK: Items

        var itemMapper: ItemMapper { get }
        var itemDataSourceFactory: DataSourceFactory<ItemModel> { get }
        var itemRepositoryFactory: RepositoryFactory<any ItemRepository> { get }
        var createItemUseCaseFactory: UseCaseFactory<CreateItemUseCase> { get }
        var updateItemUseCaseFactory: UseCaseFactory<UpdateItemUseCase> { get }
        var getItemQueryHandler: GetItemQueryHandler { get }
        var listItemsQueryHandler: ListItemsQueryHandler { get }
        var createItemCommandHandler: CreateItemCommandHandler { get }
        var updateItemCommandHandler: UpdateItemCommandHandler { get }

        // USER_LIFECYCLE_BEGIN
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
        // USER_LIFECYCLE_END
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

        // GCP

        var config: GoogleCloudPlatform.Configuration {
            resolver.resolve(\.config) {
                app.gcp.config
            }
        }

        var authProvider: any GCPAuthProvider {
            resolver.resolve(\.authProvider) {
                app.gcp.authProvider
            }
        }

        var firestore: Firestore<HTTP2ClientTransport.Posix> {
            resolver.resolve(\.firestore) {
                .create(with: config, using: authProvider)
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
                InMemoryIntegrationEventDispatcher(logger: app.logger)
            }
        }

        var integrationEventChannel: any IntegrationEventChannel {
            resolver.resolve(\.integrationEventChannel) {
                InMemoryIntegrationEventChannel(
                    dispatcher: integrationEventDispatcher,
                    logger: app.logger,
                )
            }
        }

        var domainEventDispatcher: any DomainEventDispatcher {
            resolver.resolve(\.domainEventDispatcher) {
                InMemoryDomainEventDispatcher(logger: app.logger)
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
                // so it binds a *direct* (non-transactional) Firestore store, and
                // publishes through the existing integration-event channel.
                let store = FirestoreOutboxStore(
                    transaction: .direct(firestore: firestore),
                    collection: outbox.collection,
                    logger: app.logger
                )
                return outbox.relay(
                    store: store,
                    channel: integrationEventChannel,
                    logger: app.logger
                )
            }
        }

        var unitOfWork: any UnitOfWork {
            resolver.resolve(\.unitOfWork) {
                FirestoreTransactionUnitOfWork(
                    firestore: firestore,
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
                let path = firestorePrefix(FirestoreIdempotencyStore.defaultCollection)
                let ttl = idempotencyConfiguration.ttl
                return { [logger = app.logger] ctx in
                    // Sibling force-cast pattern in CompositionRoot+Items.swift / +IAM.swift;
                    // the Firestore idempotency store requires the production FirestoreTransaction.
                    guard let txn = ctx.transaction as? FirestoreTransaction else {
                        preconditionFailure(
                            "FirestoreIdempotencyStore requires a FirestoreTransaction, but received \(type(of: ctx.transaction)); the idempotency store must run inside FirestoreTransactionUnitOfWork."
                        )
                    }
                    return FirestoreIdempotencyStore(
                        transaction: txn,
                        collectionPath: path,
                        ttl: ttl,
                        logger: logger
                    )
                }
            }
        }

        // Inbox (idempotent consumer)

        var inboxConfiguration: InboxConfiguration {
            resolver.resolve(\.inboxConfiguration) {
                .default
            }
        }

        var inboxStoreFactory: InboxStoreFactory {
            resolver.resolve(\.inboxStoreFactory) {
                let path = firestorePrefix(FirestoreInboxStore.defaultCollection)
                let ttl = inboxConfiguration.ttl
                return { [logger = app.logger] ctx in
                    guard let txn = ctx.transaction as? FirestoreTransaction else {
                        preconditionFailure(
                            "FirestoreInboxStore requires a FirestoreTransaction, but received \(type(of: ctx.transaction)); the inbox store must run inside FirestoreTransactionUnitOfWork."
                        )
                    }
                    return FirestoreInboxStore(
                        transaction: txn,
                        collectionPath: path,
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

            if let cached = persistent[keyPath] as? T {
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
