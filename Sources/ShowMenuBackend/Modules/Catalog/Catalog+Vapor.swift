import Vapor


/// A duplicate SKU is a conflict (409), not the provisional DomainError default
/// by accident: the status is stated explicitly (see `docs/conventions/HTTPErrors.md`).
extension PlanSKUAlreadyExistsError: HTTPStatusHinted {
    var httpStatusHint: HTTPResponseStatus { .conflict }
}

extension PlanFeatureNotFoundError: HTTPStatusHinted {
    var httpStatusHint: HTTPResponseStatus { .notFound }
}
