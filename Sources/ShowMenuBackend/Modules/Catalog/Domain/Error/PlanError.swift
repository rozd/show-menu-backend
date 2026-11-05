import Foundation

struct PlanNotFoundError: Error {
    let planId: Plan.Id
}

/// Another plan already uses this SKU. Mapped to 409 at the edge
/// (`Catalog+Vapor.swift` adds `HTTPStatusHinted`); the domain stays HTTP-free.
struct PlanSKUAlreadyExistsError: DomainError, LocalizedError, Equatable {
    let sku: String
    var errorDescription: String? { "Plan with SKU \(sku) already exists" }
}

/// The plan does not contain the feature. Mapped to 404 via `ApplicationError`-style
/// hint in `Catalog+Vapor.swift`.
struct PlanFeatureNotFoundError: DomainError, LocalizedError, Equatable {
    let planId: Plan.Id
    let featureId: Feature.Id
    var errorDescription: String? { "Feature with id \(featureId.rawValue) not found in plan \(planId.rawValue)" }
}
