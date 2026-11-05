import Foundation
import Logging

struct CreatePlanUseCase: UseCase {
    struct Params: Sendable {
        let payload: CreatePlanCommand.Payload
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any PlanRepository>
    let mapper: any Mapper<Plan, PlanModel, PlanDTO>
    let logger: Logger

    func execute(params: Params) async throws -> PlanDTO {
        logger.info("Executing CreatePlanUseCase")
        let payload = params.payload

        // Parse + validate first (422) so a bad request never costs a read.
        guard let sku = payload.SKU, !sku.isEmpty else { throw Plan.Error.skuRequired }
        guard let rawName = payload.name else { throw Plan.Error.nameRequired }
        guard let rawDescription = payload.description else { throw Plan.Error.descriptionRequired }
        guard let isActive = payload.isActive else { throw Plan.Error.isActiveRequired }
        let name = try LocalizedString(rawName)
        let description = try LocalizedString(rawDescription)
        let prices = try (payload.prices ?? []).map { input -> PlanPrice in
            guard let price = input.price else { throw Plan.Error.pricesRequired }
            return PlanPrice(price: try price.toPrice(), duration: try Plan.parseDuration(input.duration))
        }
        let features = try (payload.features ?? []).map { input -> PlanFeature in
            guard let featureId = input.featureId, !featureId.isEmpty else { throw Plan.Error.featureIdRequired }
            guard let quota = input.quota, let limit = quota.limit else { throw Plan.Error.quotaRequired }
            return PlanFeature(
                featureId: Feature.Id(rawValue: featureId),
                quota: FeatureQuota(unit: try Plan.parseQuotaUnit(quota.unit), limit: limit)
            )
        }

        let plan = try Plan.create(
            SKU: sku,
            name: name,
            description: description,
            isActive: isActive,
            prices: prices,
            features: features
        )

        // SKU uniqueness. The pinned FirebaseAPI cannot query inside a transaction
        // (roadmap §7, S05), so this is a plain read just before the insert: a
        // concurrent create of the same SKU in that window is not detected.
        let repository = repositoryFactory(context)
        if try await repository.fetch(bySKU: sku) != nil {
            throw PlanSKUAlreadyExistsError(sku: sku)
        }
        try await repository.insert(entity: plan)

        return mapper.toDTO(entity: plan)
    }
}
