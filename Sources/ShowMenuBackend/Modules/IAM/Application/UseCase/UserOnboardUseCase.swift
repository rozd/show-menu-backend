import Foundation
import Logging

struct UserOnboardUseCase: UseCase {
    struct Params: Sendable {
        let userId: User.Id
        let email: String?
        let name: String?
        let avatarURL: String?
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any UserRepository>
    let logger: Logger

    func execute(params: Params) async throws -> Void {
        logger.info("Executing UserOnboardUseCase", metadata: [
            "userId": .string(params.userId.rawValue)
        ])
        try User.validate(id: params.userId.rawValue)

        let repository = repositoryFactory(context)

        // Idempotent: if the user already exists, succeed silently — except for a bare
        // profile left by `UserLinkAccountUseCase` (account event overtook this one),
        // which is completed from the Auth user. `accounts` is never touched.
        if let existing = try await repository.fetch(byId: params.userId) {
            if existing.completeProfile(email: params.email, name: params.name, avatarURL: params.avatarURL) {
                logger.info("Completing the bare profile created by an account link", metadata: [
                    "userId": .string(params.userId.rawValue)
                ])
                try await repository.update(entity: existing)
            } else {
                logger.info("User already exists, skipping onboard", metadata: [
                    "userId": .string(params.userId.rawValue)
                ])
            }
            return
        }

        // Every Auth user gets a profile document, admins included (Node skipped
        // them, which broke purchases for admins).
        let user = User(
            id: params.userId,
            email: params.email,
            name: params.name,
            avatarURL: params.avatarURL,
            createdAt: .now
        )

        try await repository.insert(entity: user)
    }
}
