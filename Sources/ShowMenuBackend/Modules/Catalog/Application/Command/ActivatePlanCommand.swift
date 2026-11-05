import Foundation

struct ActivatePlanCommand: Command {
    struct Payload: Sendable, Codable {}

    let planId: String
    let payload: Payload = .init()
    let metadata: CommandMetadata
}
