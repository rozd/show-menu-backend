//
//  ContractPrincipalMiddleware.swift
//  ShowMenuBackend
//
//  Binds the Passage principal for contract routes without ever rejecting.
//

import Passage
import Vapor

/// Binds the Passage-authenticated user, if any, to `RequestContext.principal` for the
/// duration of the request.
///
/// It **never rejects**: no token, an invalid token or an unknown account all call `next`
/// with no principal. Whether a principal is *required* is decided per operation by
/// ``ContractAccessMiddleware`` (and, as a backstop, by the fail-closed use-case PEPs), so a
/// public operation stays reachable with garbage credentials.
///
/// Group it **after** ``OptionalPassageBearerAuthenticator``, which populates
/// `request.passage.user`. Do not add `PassageGuard` here: it rejects.
struct ContractPrincipalMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let principal = try await PassagePrincipalResolver.principal(for: request) else {
            return try await next.respond(to: request)
        }
        return try await RequestContext.$principal.withValue(principal) {
            try await next.respond(to: request)
        }
    }
}
