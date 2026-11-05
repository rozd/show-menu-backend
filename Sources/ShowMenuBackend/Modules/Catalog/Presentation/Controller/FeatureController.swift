import Vapor

/// Admin-only feature endpoints. Errors are thrown as typed errors and rendered
/// by `HTTPErrorMiddleware` (`Feature.Error` → 422, `ApplicationError.notFound` → 404).
struct FeatureController: Sendable {

    let createFeatureCommandHandler: CreateFeatureCommandHandler
    let updateFeatureCommandHandler: UpdateFeatureCommandHandler

    /// `POST /api/v1/plans/features` → 200 `FeatureResponse` (Node answers 200, not 201).
    @Sendable
    func createFeature(req: Request) async throws -> FeatureDTO {
        let payload = try req.content.decode(CreateFeatureCommand.Payload.self)
        return try await createFeatureCommandHandler.handle(CreateFeatureCommand(
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }

    /// `PUT /api/v1/plans/features/:featureId` → 200 `FeatureResponse`.
    @Sendable
    func updateFeature(req: Request) async throws -> FeatureDTO {
        guard let featureId = req.parameters.get("featureId") else {
            throw Abort(.badRequest, reason: "Missing featureId parameter")
        }
        let payload = try req.content.decode(UpdateFeatureCommand.Payload.self)
        return try await updateFeatureCommandHandler.handle(UpdateFeatureCommand(
            featureId: featureId,
            payload: payload,
            metadata: CommandMetadata(req: req)
        ))
    }
}
