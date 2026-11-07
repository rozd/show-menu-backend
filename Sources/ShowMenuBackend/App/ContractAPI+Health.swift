import OpenAPIRuntime
import ShowMenuContracts
import Vapor

/// The two platform operations that belong to no module: liveness and build info.
extension ContractAPI {

    func getHealth(_ input: Operations.GetHealth.Input) async throws -> Operations.GetHealth.Output {
        .ok(.init(body: .json(.init(status: .ok))))
    }

    func getVersion(_ input: Operations.GetVersion.Input) async throws -> Operations.GetVersion.Output {
        .ok(.init(body: .plainText(HTTPBody(Environment.buildInfo))))
    }
}
