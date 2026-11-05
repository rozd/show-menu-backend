import Foundation
import Logging

/// Idempotent: deactivateing a plan that is already in the target state is a no-op
/// for the aggregate (no semantic event, `updatedAt` kept) and still succeeds.
struct DeactivatePlanUseCase: UseCase {
    struct Params: Sendable {
        let planId: Plan.Id
    }

    let context: any UnitOfWorkContext
    let repositoryFactory: RepositoryFactory<any PlanRepository>
    let logger: Logger

    func execute(params: Params) async throws {
        logger.info("Executing DeactivatePlanUseCase", metadata: ["planId": .string(params.planId.rawValue)])
        let repository = repositoryFactory(context)
        guard let plan = try await repository.fetch(byId: params.planId) else {
            throw ApplicationError.notFound(entity: "Plan", id: params.planId)
        }
        // Always persisted, even when already in the target state: a Firestore transaction
        // that commits without a write fails (`commitFailed`), and Node always wrote too.
        // `deactivate()` is a no-op (no event, `updatedAt` untouched) in that case.
        plan.deactivate()
        try await repository.update(entity: plan)
    }
}
