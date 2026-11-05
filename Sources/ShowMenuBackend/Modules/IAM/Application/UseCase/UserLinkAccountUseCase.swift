import Foundation
import Logging

/// Adds an account id to its creator's `users/{uid}.accounts` (Node's
/// `RegisterAccountUseCase`).
///
/// **The user document may not exist yet.** The account-create event can overtake
/// the user-create event (both arrive as independent webhooks, and a failed
/// handler is logged and swallowed — the forwarder never redelivers). Failing
/// here would lose the link for good, so a missing user is *upserted* as a
/// minimal profile `{id, accounts: [accountId], createdAt, updatedAt}` with no
/// email/name/avatar. `UserOnboardUseCase` later completes such a bare profile
/// instead of skipping it, and never touches `accounts`.
struct UserLinkAccountUseCase: UseCase {
    struct Params: Sendable {
        let accountId: String
    }

    let context: any UnitOfWorkContext
    let accountDataSourceFactory: DataSourceFactory<AccountModel>
    let accountMapper: AccountMapper
    let repositoryFactory: RepositoryFactory<any UserRepository>
    let logger: Logger

    func execute(params: Params) async throws -> Void {
        logger.info("Executing UserLinkAccountUseCase", metadata: [
            "accountId": .string(params.accountId)
        ])

        // The creator is read from the stored account, never trusted from the event
        // (same source of identity as the owner grant). Read first: the pinned
        // Firestore client forbids reads after writes.
        guard let accountModel = try await accountDataSourceFactory("", context.transaction).fetch(byId: params.accountId) else {
            // Permanent condition: throwing would make the runner retry 5× for nothing.
            logger.warning("Account not found, skipping link", metadata: [
                "accountId": .string(params.accountId)
            ])
            return
        }
        let userId = User.Id(rawValue: try accountMapper.toEntity(model: accountModel).creator)
        try User.validate(id: userId.rawValue)

        let repository = repositoryFactory(context)

        guard let user = try await repository.fetch(byId: userId) else {
            logger.info("User not onboarded yet, creating a minimal profile to hold the link", metadata: [
                "userId": .string(userId.rawValue)
            ])
            let placeholder = User(id: userId)
            placeholder.addAccount(params.accountId)
            try await repository.insert(entity: placeholder)
            return
        }

        // Idempotent: already linked → nothing to write.
        guard !user.accounts.contains(params.accountId) else {
            logger.info("Account already linked, skipping", metadata: [
                "userId": .string(userId.rawValue)
            ])
            return
        }

        user.addAccount(params.accountId)
        try await repository.update(entity: user)
    }
}
