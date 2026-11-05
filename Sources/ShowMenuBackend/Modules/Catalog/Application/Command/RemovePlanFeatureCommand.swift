import Foundation

struct RemovePlanFeatureCommand: Command {
    struct Payload: Sendable, Codable {}

    let planId: String
    let featureId: String
    let payload: Payload = .init()
    let metadata: CommandMetadata
}
