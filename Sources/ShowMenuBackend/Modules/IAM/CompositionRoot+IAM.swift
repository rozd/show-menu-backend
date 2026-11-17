import Vapor

extension Application.CompositionRoot {

    // MARK: IAM — Mappers

    var userMapper: UserMapper {
        resolver.resolve(\.userMapper) {
            UserMapper()
        }
    }

    // MARK: IAM — Data Sources

    /// **Store binding** — the Fluent adapter. The first argument (a collection
    /// path) is unused: the table is fixed by the model's `FluentDataSource.table`.
    var userDataSourceFactory: DataSourceFactory<UserModel> {
        resolver.resolve(\.userDataSourceFactory) {
            { [logger = app.logger] _, transaction in
                FluentUserDataSource(
                    transaction: transaction as! FluentTransaction,
                    logger: logger
                )
            }
        }
    }

    // MARK: IAM — Repositories

    var userRepositoryFactory: RepositoryFactory<any UserRepository> {
        resolver.resolve(\.userRepositoryFactory) {
            { ctx in
                DefaultUserRepository(
                    mapper: userMapper,
                    dataSourceFactory: userDataSourceFactory,
                    context: ctx
                )
            }
        }
    }

    // MARK: IAM — Use Cases

    var userOnboardUseCaseFactory: UseCaseFactory<UserOnboardUseCase> {
        resolver.resolve(\.userOnboardUseCaseFactory) {
            { [logger = app.logger] ctx in
                UserOnboardUseCase(
                    context: ctx,
                    repositoryFactory: userRepositoryFactory,
                    logger: logger
                )
            }
        }
    }

    var userRemoveUseCaseFactory: UseCaseFactory<UserRemoveUseCase> {
        resolver.resolve(\.userRemoveUseCaseFactory) {
            { [logger = app.logger] ctx in
                UserRemoveUseCase(
                    context: ctx,
                    repositoryFactory: userRepositoryFactory,
                    ability: RemoveUserAbility(),
                    logger: logger
                )
            }
        }
    }

    // MARK: IAM — Query Handlers

    var getUserQueryHandler: GetUserQueryHandler {
        resolver.resolve(\.getUserQueryHandler) {
            GetUserQueryHandler(
                dataSourceFactory: userDataSourceFactory,
                transaction: directTransaction,
                mapper: userMapper,
                logger: app.logger
            )
        }
    }

    var findUserQueryHandler: FindUserQueryHandler {
        resolver.resolve(\.findUserQueryHandler) {
            FindUserQueryHandler(
                dataSourceFactory: userDataSourceFactory,
                transaction: directTransaction,
                mapper: userMapper,
                logger: app.logger
            )
        }
    }

    // MARK: IAM — Command Handlers

    var createUserAccountCommandHandler: CreateUserAccountCommandHandler {
        resolver.resolve(\.createUserAccountCommandHandler) {
            CreateUserAccountCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: userOnboardUseCaseFactory,
                inbox: InboxComponents(storeFactory: inboxStoreFactory, configuration: inboxConfiguration),
                logger: app.logger
            )
        }
    }

    var deleteUserAccountCommandHandler: DeleteUserAccountCommandHandler {
        resolver.resolve(\.deleteUserAccountCommandHandler) {
            DeleteUserAccountCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: userRemoveUseCaseFactory,
                inbox: InboxComponents(storeFactory: inboxStoreFactory, configuration: inboxConfiguration),
                logger: app.logger
            )
        }
    }

    // MARK: IAM — Integration Event Handlers

    var userCreatedIntegrationEventHandler: UserCreatedIntegrationEventHandler {
        resolver.resolve(\.userCreatedIntegrationEventHandler) {
            UserCreatedIntegrationEventHandler(
                commandHandler: createUserAccountCommandHandler,
                logger: app.logger
            )
        }
    }

    var userDeletedIntegrationEventHandler: UserDeletedIntegrationEventHandler {
        resolver.resolve(\.userDeletedIntegrationEventHandler) {
            UserDeletedIntegrationEventHandler(
                commandHandler: deleteUserAccountCommandHandler,
                logger: app.logger
            )
        }
    }
}
