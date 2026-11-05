import Foundation

struct UpdateFeatureCommand: Command {
    /// Partial update: absent/`null` fields keep their current value.
    struct Payload: Sendable, Codable {
        let category: String?
        let name: [String: String]?
        let description: [String: String]?
    }

    let featureId: String
    let payload: Payload
    let metadata: CommandMetadata
}
