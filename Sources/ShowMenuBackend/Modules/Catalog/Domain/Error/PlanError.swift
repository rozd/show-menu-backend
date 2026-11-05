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
