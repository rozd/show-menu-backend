import Foundation

struct CreateItemCommand: Command {
    struct Payload: Sendable, Codable {
        let name: String
        let description: String?
    }

    let payload: Payload
    let metadata: CommandMetadata
}
