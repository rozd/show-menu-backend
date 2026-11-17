//
//  OptionalPassageBearerAuthenticator.swift
//  ShowMenuBackend
//
//  Passage's bearer authenticator, made lenient.
//

import Passage
import Vapor

/// Runs `PassageBearerAuthenticator` but swallows its failures.
///
/// Passage's own authenticator **does throw** on a bad credential: it verifies the JWT with
/// `request.jwt.verify` (a malformed, expired or wrongly signed token throws a `JWTError`) and
/// then loads the account (`AuthenticationError.userNotFound`). That is right behind
/// `PassageGuard`, but wrong for the contract routes, where a public operation must keep
/// working when the client sends a stale token. Here a failure just means "unauthenticated":
/// the request continues without a Passage user and the per-operation access table decides.
///
/// `next` is deliberately called outside the `do/catch`, so a handler error is never
/// mistaken for an authentication failure.
struct OptionalPassageBearerAuthenticator: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let bearer = request.headers.bearerAuthorization {
            do {
                try await PassageBearerAuthenticator().authenticate(bearer: bearer, for: request)
            } catch {
                request.logger.debug("Ignoring invalid bearer credential", metadata: ["error": .string(String(describing: type(of: error)))])
            }
        }
        return try await next.respond(to: request)
    }
}
