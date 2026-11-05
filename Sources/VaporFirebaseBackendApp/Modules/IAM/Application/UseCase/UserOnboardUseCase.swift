import Foundation
import Logging

struct UserOnboardUseCase: UseCase {
    struct Params: Sendable {
        let userId: User.Id
        let email: String?
        let displayName: String?
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

        // Idempotent: if user already exists, succeed silently.
        guard try await repository.fetch(byId: params.userId) == nil else {
            logger.info("User already exists, skipping onboard", metadata: [
                "userId": .string(params.userId.rawValue)
            ])
            return
        }

        let user = User(
            id: params.userId,
            email: params.email,
            displayName: params.displayName,
            photoURL: nil,
            emailVerified: false,
            disabled: false,
            createdAt: .now
        )

        try await repository.insert(entity: user)
    }
}
