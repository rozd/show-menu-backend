import ShowMenuContracts
import Vapor

/// Admin-only feature operations. Errors are thrown as typed errors and rendered by
/// `HTTPErrorMiddleware` (`Feature.Error` → 422, `ApplicationError.notFound` → 404).
struct FeatureController: Sendable {

    let createFeatureCommandHandler: CreateFeatureCommandHandler
    let updateFeatureCommandHandler: UpdateFeatureCommandHandler

    /// `createFeature` → 200 `Feature` (Node answers 200, not 201).
    func createFeature(
        _ input: Operations.CreateFeature.Input
    ) async throws -> Operations.CreateFeature.Output {
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let dto = try await createFeatureCommandHandler.handle(CreateFeatureCommand(
            payload: CatalogWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }

    /// `updateFeature` → 200 `Feature`.
    func updateFeature(
        _ input: Operations.UpdateFeature.Input
    ) async throws -> Operations.UpdateFeature.Output {
        guard case let .json(body) = input.body else { throw Abort(.badRequest, reason: "Unsupported request body") }
        let dto = try await updateFeatureCommandHandler.handle(UpdateFeatureCommand(
            featureId: input.path.featureId,
            payload: CatalogWireMapper.payload(body),
            metadata: CommandMetadata()
        ))
        return .ok(.init(body: .json(try CatalogWireMapper.wire(dto))))
    }
}
