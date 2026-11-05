import Foundation

struct DeactivatePlanCommand: Command {
    struct Payload: Sendable, Codable {}

    let planId: String
    let payload: Payload = .init()
    let metadata: CommandMetadata
}
