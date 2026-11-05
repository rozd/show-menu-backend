import Foundation

struct CreateUserAccountCommand: Command {
    struct Payload: Sendable, Codable {
        let userId: String
        let email: String?
        let displayName: String?
        let photoURL: String?
    }

    let payload: Payload
    let metadata: CommandMetadata
}
