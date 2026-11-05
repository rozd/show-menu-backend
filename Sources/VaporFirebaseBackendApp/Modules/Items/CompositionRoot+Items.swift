import Vapor

extension Application.CompositionRoot {

    // MARK: Items — Mappers

    var itemMapper: ItemMapper {
        resolver.resolve(\.itemMapper) {
            ItemMapper()
        }
    }

    // MARK: Items — Data Sources

    var itemDataSourceFactory: DataSourceFactory<ItemModel> {
        resolver.resolve(\.itemDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreItemDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    // MARK: Items — Repositories

    var itemRepositoryFactory: RepositoryFactory<any ItemRepository> {
        resolver.resolve(\.itemRepositoryFactory) {
            { ctx in
                FirestoreItemRepository(
                    mapper: itemMapper,
                    dataSourceFactory: itemDataSourceFactory,
                    context: ctx,
                )
            }
        }
    }

    // MARK: Items — Use Cases

    var createItemUseCaseFactory: UseCaseFactory<CreateItemUseCase> {
        resolver.resolve(\.createItemUseCaseFactory) {
            { [logger = app.logger] ctx in
                CreateItemUseCase(
                    context: ctx,
                    repositoryFactory: itemRepositoryFactory,
                    mapper: itemMapper,
                    logger: logger
                )
            }
        }
    }

    var updateItemUseCaseFactory: UseCaseFactory<UpdateItemUseCase> {
        resolver.resolve(\.updateItemUseCaseFactory) {
            { [logger = app.logger] ctx in
                UpdateItemUseCase(
                    context: ctx,
                    repositoryFactory: itemRepositoryFactory,
                    mapper: itemMapper,
                    logger: logger
                )
            }
        }
    }

    // MARK: Items — Query Handlers

    var getItemQueryHandler: GetItemQueryHandler {
        resolver.resolve(\.getItemQueryHandler) {
            GetItemQueryHandler(
                dataSourceFactory: itemDataSourceFactory,
                transaction: .direct(firestore: firestore),
                mapper: itemMapper,
                logger: app.logger,
            )
        }
    }

    var listItemsQueryHandler: ListItemsQueryHandler {
        resolver.resolve(\.listItemsQueryHandler) {
            ListItemsQueryHandler(
                dataSourceFactory: itemDataSourceFactory,
                transaction: .direct(firestore: firestore),
                mapper: itemMapper,
                logger: app.logger,
            )
        }
    }

    // MARK: Items — Command Handlers

    // Both write endpoints conform to `IdempotentCommandHandler`: the protocol's
    // default `handle` shares the handler's own UnitOfWork, so reserve/replay/store
    // run inside the same Firestore transaction as the command's writes. The
    // concrete handler type is kept end-to-end (no decorator / type erasure).

    var createItemCommandHandler: CreateItemCommandHandler {
        resolver.resolve(\.createItemCommandHandler) {
            CreateItemCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: createItemUseCaseFactory,
                idempotency: IdempotencyComponents(
                    storeFactory: idempotencyStoreFactory,
                    configuration: idempotencyConfiguration
                ),
                logger: app.logger
            )
        }
    }

    var updateItemCommandHandler: UpdateItemCommandHandler {
        resolver.resolve(\.updateItemCommandHandler) {
            UpdateItemCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: updateItemUseCaseFactory,
                idempotency: IdempotencyComponents(
                    storeFactory: idempotencyStoreFactory,
                    configuration: idempotencyConfiguration
                ),
                logger: app.logger
            )
        }
    }
}
