import Foundation

struct LinkAccountToCreatorCommand: Command {
    struct Payload: Sendable, Codable {
        let accountId: String
        let creatorId: String
    }

    let payload: Payload
    let metadata: CommandMetadata
}
