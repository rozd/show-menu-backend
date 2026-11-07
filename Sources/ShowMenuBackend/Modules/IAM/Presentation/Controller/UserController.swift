import Logging
import ShowMenuContracts
import Vapor

struct UserController: Sendable {
    let getUserQueryHandler: GetUserQueryHandler
    let findUserQueryHandler: FindUserQueryHandler
    let logger: Logger

    // MARK: - Operations

    /// `getUser` -> 200 `User`; unknown id -> 404 (`not_found`).
    func getUser(_ input: Operations.GetUser.Input) async throws -> Operations.GetUser.Output {
        let userId = input.path.userId

        do {
            guard let dto = try await getUserQueryHandler.handle(GetUserQuery(userId: userId)) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return .ok(.init(body: .json(try IAMWireMapper.wire(dto))))
        } catch let error as FirestoreError {
            logger.error("Firestore error", metadata: [
                "userId": .string(userId),
                "error": .string(error.localizedDescription)
            ])
            throw Self.mapped(error)
        }
    }

    /// `findUsers` -> 200 `[User]` (a bare array); neither filter given -> 400.
    func findUsers(_ input: Operations.FindUsers.Input) async throws -> Operations.FindUsers.Output {
        let displayName = input.query.displayName
        let email = input.query.email

        guard displayName != nil || email != nil else {
            throw Abort(.badRequest, reason: "At least one filter required: displayName or email")
        }

        do {
            let dtos = try await findUserQueryHandler.handle(
                FindUserQuery(displayName: displayName, email: email)
            )
            return .ok(.init(body: .json(try dtos.map(IAMWireMapper.wire))))
        } catch let error as FirestoreError {
            logger.error("Firestore error", metadata: [
                "error": .string(error.localizedDescription)
            ])
            throw Self.mapped(error)
        }
    }

    /// Only an unavailable Firestore is a 503; every other Firestore failure is an opaque 500.
    private static func mapped(_ error: FirestoreError) -> Abort {
        switch error {
        case .serviceUnavailable:
            Abort(.serviceUnavailable, reason: "Service temporarily unavailable")
        default:
            Abort(.internalServerError, reason: "Internal server error")
        }
    }
}
