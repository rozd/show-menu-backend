import Vapor

/// The authenticated caller of an API request, derived from a verified Firebase
/// ID token. `id` is the Firebase uid (token `sub`); `admin == true` in the token
/// grants ``Role/admin`` (D5).
struct FirebasePrincipal: Principal {
    let id: String
    let email: String?
    let roles: Set<Role>

    init(id: String, email: String? = nil, roles: Set<Role> = []) {
        self.id = id
        self.email = email
        self.roles = roles
    }

    init(token: FirebaseIDToken) {
        self.init(
            id: token.sub.value,
            email: token.email,
            roles: token.admin == true ? [.admin] : []
        )
    }
}

/// Authentication gate: requires `Authorization: Bearer <Firebase ID token>`,
/// verifies it, and binds the resulting `Principal` to `RequestContext.principal`
/// for the rest of the request. A missing or invalid token is a 401 through the
/// error envelope.
struct FirebaseAuthMiddleware: AsyncMiddleware {
    let verifier: FirebaseTokenVerifier

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing bearer token")
        }
        let principal: FirebasePrincipal
        do {
            principal = FirebasePrincipal(token: try await verifier.verify(bearer.token))
        } catch let error as FirebaseJWKSUnavailableError {
            // Infrastructure failure, not a bad token: 503 via the envelope.
            throw error
        } catch {
            request.logger.debug("Bearer token rejected", metadata: [
                "error": .string(String(describing: error))
            ])
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
        return try await RequestContext.$principal.withValue(principal) {
            try await next.respond(to: request)
        }
    }
}

/// Restricts a route group to administrators (403 otherwise). Must run after
/// ``FirebaseAuthMiddleware``; fails closed (401) when no principal is bound.
struct RequireAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let principal = RequestContext.principal else {
            throw AuthorizationError.missingPrincipal
        }
        guard principal.roles.contains(.admin) else {
            throw AuthorizationError.denied(reason: "Admin role required")
        }
        return try await next.respond(to: request)
    }
}
