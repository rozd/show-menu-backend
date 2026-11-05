import Foundation

struct CreateFeatureCommand: Command {
    /// Every field is optional so that a missing one surfaces as a domain
    /// `ValidationError` (422) instead of a 400 decoding failure.
    struct Payload: Sendable, Codable {
        let category: String?
        let name: [String: String]?
        let description: [String: String]?
    }

    let payload: Payload
    let metadata: CommandMetadata
}
