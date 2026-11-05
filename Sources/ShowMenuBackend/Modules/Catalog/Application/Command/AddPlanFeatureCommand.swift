import Foundation

struct AddPlanFeatureCommand: Command {
    typealias Payload = CreatePlanCommand.FeatureInput

    let planId: String
    let payload: Payload
    let metadata: CommandMetadata
}
