//
//  PassagePrincipalMiddleware.swift
//  ShowMenuBackend
//
//  Bridges the authenticated Passage user into the authorization context.
//

import Passage
import Vapor

/// Binds the authenticated Passage user to `RequestContext.principal` for the
/// duration of the request, exactly as `TraceMiddleware` binds `traceId`.
///
/// This is the anti-corruption layer between the two identity worlds: Passage
/// answers *who* the caller is; the IAM module answers *what they may do*.
/// Roles are resolved from IAM's `User` record on every request — one indexed
/// point read — so revoking a role takes effect immediately rather than when
/// the access token expires. Everything below this middleware talks only to
/// the `Principal` protocol and never sees a Passage type.
///
/// Order matters: group it **after** `PassageBearerAuthenticator` and
/// `PassageGuard`, which guarantee an authenticated user is present.
///
/// Returns **401** if the user was deleted (concurrent deletion of the
/// authenticated account) — the Passage authenticator just loaded the same
/// row, so a miss is only an account-state change by another request, not
/// a server fault.
struct PassagePrincipalMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let user = try request.passage.user
        guard let userId = user.identifierString else {
            throw Abort(.unauthorized, reason: "Authenticated user has no id.")
        }

        let deps = request.application.deps
        let dto = try await deps.getUserQueryHandler.handle(GetUserQuery(userId: userId))

        guard let dto else {
            // Account no longer exists — concurrent delete by another request.
            // The Passage authenticator just loaded the same row, so this is
            // purely a caller-state issue, not a server fault.
            throw Abort(.unauthorized, reason: "Account no longer exists.")
        }

        let principal = PassagePrincipal(
            id: userId,
            roles: Set((dto.roles ?? []).map(Role.init(rawValue:)))
        )
        return try await RequestContext.$principal.withValue(principal) {
            try await next.respond(to: request)
        }
    }
}
