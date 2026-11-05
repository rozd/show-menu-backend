import Foundation
import Logging

struct UserRemoveUseCase: UseCase {
    struct Params: Sendable {
        let userId: User.Id
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any UserRepository>
    let ability: RemoveUserAbility
    let logger: Logger

    func execute(params: Params) async throws -> Void {
        logger.info("Executing UserRemoveUseCase", metadata: [
            "userId": .string(params.userId.rawValue)
        ])
        let repository = repositoryFactory(context)

        // Idempotent: if user doesn't exist, succeed silently.
        guard let user = try await repository.fetch(byId: params.userId) else {
            logger.info("User not found, skipping remove", metadata: [
                "userId": .string(params.userId.rawValue)
            ])
            return
        }

        // Policy Enforcement Point: authorize the actor against the loaded
        // aggregate before any mutation. Fail closed when no principal is present.
        guard let principal = RequestContext.principal else {
            throw AuthorizationError.missingPrincipal
        }
        switch ability.evaluate(principal: principal, subject: user) {
        case .allowed:
            break
        case .denied(let reason):
            logger.notice("UserRemoveUseCase denied", metadata: [
                "userId": .string(params.userId.rawValue),
                "principal": .string(principal.id),
                "reason": .string(reason)
            ])
            throw AuthorizationError.denied(reason: reason)
        }

        try await repository.delete(entity: user)
    }
}
