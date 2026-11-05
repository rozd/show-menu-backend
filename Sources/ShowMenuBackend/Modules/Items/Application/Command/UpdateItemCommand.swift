import Foundation

struct UpdateItemCommand: Command {
    struct Payload: Sendable, Codable {
        let name: String
        let description: String?
    }

    let itemId: String

    /// The `If-Match` precondition the client supplied, if any. When present it
    /// is enforced as the expected concurrency token; `nil` means "no caller
    /// precondition" and the write relies on the loaded token.
    let expectedEntityVersion: Version?

    let payload: Payload
    let metadata: CommandMetadata
}
