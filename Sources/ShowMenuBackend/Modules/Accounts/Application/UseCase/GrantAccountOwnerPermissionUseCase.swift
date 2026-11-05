import Foundation
import Logging

/// Gives an account's creator the `owner` role on it:
/// `accounts/{id}/permissions/{creator}` = `{role: "owner", permissions: []}`
/// (Node's `SetInitialAccountPermissionsUseCase`).
///
/// The creator is read from the account document, not trusted from the event, so
/// a deleted account never gets a permission document. Idempotent (`set`).
struct GrantAccountOwnerPermissionUseCase: UseCase {
    struct Params: Sendable {
        let accountId: String
    }

    static let ownerRole = "owner"

    let context: any UnitOfWorkContext
    let accountDataSourceFactory: DataSourceFactory<AccountModel>
    let accountMapper: AccountMapper
    let permissionStoreFactory: @Sendable (_ ctx: any UnitOfWorkContext) -> any AccountPermissionStore
    let logger: Logger

    func execute(params: Params) async throws -> Void {
        logger.info("Executing GrantAccountOwnerPermissionUseCase", metadata: [
            "accountId": .string(params.accountId)
        ])

        // Read first: the pinned Firestore client forbids reads after writes.
        guard let model = try await accountDataSourceFactory("", context.transaction).fetch(byId: params.accountId) else {
            // Permanent condition: throwing would make the transaction runner retry
            // 5× for nothing. Log and commit without writes.
            logger.warning("Account not found, skipping owner grant", metadata: [
                "accountId": .string(params.accountId)
            ])
            return
        }
        let account = try accountMapper.toEntity(model: model)

        try await permissionStoreFactory(context).put(
            AccountPermissionModel(role: Self.ownerRole, permissions: []),
            accountId: account.id,
            userId: account.creator
        )
    }
}
