import Foundation

struct UpdatePlanCommand: Command {
    /// Node requires both fields (`UpdatePlanRequest`); a missing one is a 422.
    struct Payload: Sendable, Codable {
        let name: [String: String]?
        let description: [String: String]?
    }

    let planId: String
    let payload: Payload
    let metadata: CommandMetadata
}
