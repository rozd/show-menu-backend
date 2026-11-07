import HTTPTypes
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

/// Authenticates a request from its `Authorization: Bearer <Firebase ID token>` header
/// and returns the resulting ``FirebasePrincipal``. A missing or invalid token is a 401
/// through the error envelope; a JWKS outage is rethrown (503). The caller
/// (`ContractAccessMiddleware`) binds the principal to `RequestContext.principal`.
struct FirebaseBearerAuthenticator: Sendable {
    let verifier: FirebaseTokenVerifier
    let logger: Logger

    func authenticate(headers: HTTPFields) async throws -> FirebasePrincipal {
        guard let token = headers.bearerToken else {
            throw Abort(.unauthorized, reason: "Missing bearer token")
        }
        do {
            return FirebasePrincipal(token: try await verifier.verify(token))
        } catch let error as FirebaseJWKSUnavailableError {
            // Infrastructure failure, not a bad token: 503 via the envelope.
            throw error
        } catch {
            logger.debug("Bearer token rejected", metadata: [
                "error": .string(String(describing: error))
            ])
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }
    }
}
