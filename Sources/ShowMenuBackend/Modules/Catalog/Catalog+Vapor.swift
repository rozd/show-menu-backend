import Vapor

extension FeatureDTO: Content {}
extension PlanDTO: Content {}

/// A duplicate SKU is a conflict (409), not the provisional DomainError default
/// by accident: the status is stated explicitly (see `docs/conventions/HTTPErrors.md`).
extension PlanSKUAlreadyExistsError: HTTPStatusHinted {
    var httpStatusHint: HTTPResponseStatus { .conflict }
}
