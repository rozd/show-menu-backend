import Foundation

protocol PlanRepository: Repository where Entity == Plan, Model == PlanModel, DTO == PlanDTO {
    /// Finds a plan by SKU with a query that runs on the repository's own
    /// transaction (a read, so it must precede any write of the unit of work).
    func fetch(bySKU sku: String) async throws -> Plan?
}
