import Vapor

extension Application.CompositionRoot {

    // MARK: Accounts — Mappers

    var accountMapper: AccountMapper {
        resolver.resolve(\.accountMapper) {
            AccountMapper()
        }
    }

    // MARK: Accounts — Data Sources

    var accountDataSourceFactory: DataSourceFactory<AccountModel> {
        resolver.resolve(\.accountDataSourceFactory) {
            { [logger = app.logger] prefix, transaction in
                FirestoreAccountDataSource(
                    transaction: transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(prefix),
                    logger: logger
                )
            }
        }
    }

    var accountPermissionStoreFactory: @Sendable (_ ctx: any UnitOfWorkContext) -> any AccountPermissionStore {
        resolver.resolve(\.accountPermissionStoreFactory) {
            { [logger = app.logger] ctx in
                FirestoreAccountPermissionStore(
                    transaction: ctx.transaction as! FirestoreTransaction,
                    prefix: firestorePrefix(""),
                    logger: logger
                )
            }
        }
    }

    // MARK: Accounts — Use Cases

    var grantAccountOwnerPermissionUseCaseFactory: UseCaseFactory<GrantAccountOwnerPermissionUseCase> {
        resolver.resolve(\.grantAccountOwnerPermissionUseCaseFactory) {
            { [logger = app.logger] ctx in
                GrantAccountOwnerPermissionUseCase(
                    context: ctx,
                    accountDataSourceFactory: accountDataSourceFactory,
                    accountMapper: accountMapper,
                    permissionStoreFactory: accountPermissionStoreFactory,
                    logger: logger
                )
            }
        }
    }

    // MARK: Accounts — Command Handlers

    var grantAccountOwnerPermissionCommandHandler: GrantAccountOwnerPermissionCommandHandler {
        resolver.resolve(\.grantAccountOwnerPermissionCommandHandler) {
            GrantAccountOwnerPermissionCommandHandler(
                unitOfWork: unitOfWork,
                useCaseFactory: grantAccountOwnerPermissionUseCaseFactory,
                inbox: InboxComponents(storeFactory: inboxStoreFactory),
                logger: app.logger
            )
        }
    }

    // MARK: Accounts — Integration Event Handlers

    var grantOwnerPermissionOnAccountCreatedHandler: GrantOwnerPermissionOnAccountCreatedHandler {
        resolver.resolve(\.grantOwnerPermissionOnAccountCreatedHandler) {
            GrantOwnerPermissionOnAccountCreatedHandler(
                commandHandler: grantAccountOwnerPermissionCommandHandler,
                logger: app.logger
            )
        }
    }
}
