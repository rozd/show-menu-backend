import Foundation

struct GrantAccountOwnerPermissionCommand: Command {
    struct Payload: Sendable, Codable {
        let accountId: String
    }

    let payload: Payload
    let metadata: CommandMetadata
}
