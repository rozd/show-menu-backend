//
//  PassagePrincipalResolver.swift
//  ShowMenuBackend
//
//  Bridges the authenticated Passage user into the authorization context.
//

import Passage
import Vapor

/// The anti-corruption layer between the two identity worlds: Passage answers *who* the
/// caller is; the IAM module answers *what they may do*.
///
/// Roles are resolved from IAM's `User` record on every request (one indexed point read), so
/// revoking a role takes effect immediately rather than when the access token expires.
/// Everything downstream talks only to the `Principal` protocol and never sees a Passage type.
enum PassagePrincipalResolver {

    /// The principal for the user Passage authenticated on `request`, or `nil` when there is
    /// none: no authenticated user, a user without an id, or an account IAM no longer knows
    /// (concurrent deletion). Infrastructure failures propagate.
    static func principal(for request: Request) async throws -> PassagePrincipal? {
        guard let user = try? request.passage.user,
              let userId = user.identifierString else {
            return nil
        }
        guard let dto = try await request.application.deps.getUserQueryHandler.handle(GetUserQuery(userId: userId)) else {
            return nil
        }
        return PassagePrincipal(
            id: userId,
            roles: Set(dto.roles.map(Role.init(rawValue:)))
        )
    }
}
