import Vapor

/// An unknown account is a 404 (it was an unmapped plain `Error`).
extension AccountNotFoundError: HTTPStatusHinted {
    var httpStatusHint: HTTPResponseStatus { .notFound }
}

extension AccountNotFoundError: LocalizedError {
    var errorDescription: String? { "Account \(accountId) not found" }
}
