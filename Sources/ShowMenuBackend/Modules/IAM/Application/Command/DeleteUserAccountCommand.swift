import Foundation

struct DeleteUserAccountCommand: Command {
    struct Payload: Sendable, Codable {
        let userId: String
    }

    let payload: Payload
    let metadata: CommandMetadata
}
