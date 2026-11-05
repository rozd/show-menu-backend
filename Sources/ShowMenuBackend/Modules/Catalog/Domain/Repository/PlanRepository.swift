import Foundation

protocol PlanRepository: Repository where Entity == Plan, Model == PlanModel, DTO == PlanDTO {
    /// Whether a plan already uses `sku`. Reads only, so it must run before the
    /// unit of work's first write. `insert` reserves the SKU atomically with the plan.
    func isSKUTaken(_ sku: String) async throws -> Bool
}
