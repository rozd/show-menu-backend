import Vapor

struct UserController: Sendable {
    let getUserQueryHandler: GetUserQueryHandler
    let findUserQueryHandler: FindUserQueryHandler

    // MARK: - Endpoints

    @Sendable
    func getUser(req: Request) async throws -> UserDTO {
        guard let userId = req.parameters.get("userId") else {
            throw Abort(.badRequest, reason: "Missing userId parameter")
        }

        do {
            guard let dto = try await getUserQueryHandler.handle(GetUserQuery(userId: userId)) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return dto
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: [
                "userId": .string(userId),
                "error": .string(error.localizedDescription)
            ])
            switch error {
            case .serviceUnavailable:
                throw Abort(.serviceUnavailable, reason: "Service temporarily unavailable")
            default:
                throw Abort(.internalServerError, reason: "Internal server error")
            }
        }
    }

    @Sendable
    func findUsers(req: Request) async throws -> [UserDTO] {
        let displayName: String? = req.query["displayName"]
        let email: String? = req.query["email"]

        guard displayName != nil || email != nil else {
            throw Abort(.badRequest, reason: "At least one filter required: displayName or email")
        }

        do {
            return try await findUserQueryHandler.handle(
                FindUserQuery(displayName: displayName, email: email)
            )
        } catch let error as FirestoreError {
            req.logger.error("Firestore error", metadata: [
                "error": .string(error.localizedDescription)
            ])
            switch error {
            case .serviceUnavailable:
                throw Abort(.serviceUnavailable, reason: "Service temporarily unavailable")
            default:
                throw Abort(.internalServerError, reason: "Internal server error")
            }
        }
    }
}
