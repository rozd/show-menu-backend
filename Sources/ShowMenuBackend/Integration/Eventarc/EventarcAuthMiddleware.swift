import Vapor

/// Authenticates the caller of the Eventarc webhook (`POST /`).
///
/// The gen-1 forwarders (`cloud-functions/auth-forwarder`, later the Firestore
/// forwarder) request a Google-signed OIDC identity token from the metadata
/// server with the Cloud Run service URL as audience and send it as
/// `Authorization: Bearer …`. This middleware verifies it (issuer Google,
/// audience = service URL, and — when configured — an allow-listed
/// service-account email) **before** any CloudEvent is parsed, so a forged
/// `user.deleted` cannot reach the user-removal path.
///
/// **Emulator:** the local `show-menu-firebase/forwarders` bridge has no
/// metadata server and sends no token, so verification is skipped (the same
/// relaxation `FirebaseTokenVerifier` makes for unsigned tokens).
///
/// **Unconfigured (non-emulator):** with no verifier every request is denied —
/// secure by default. Set `EVENTARC_OIDC_AUDIENCE` on the service.
struct EventarcAuthMiddleware: AsyncMiddleware {

    /// Verifies the Google-signed OIDC token; `nil` when unconfigured.
    let oidc: GoogleOIDCTokenVerifier?

    /// Skip verification entirely (emulator only).
    let bypassInEmulator: Bool

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if bypassInEmulator {
            return try await next.respond(to: request)
        }

        guard let oidc, let bearer = request.headers.bearerAuthorization else {
            request.logger.warning("Rejected unauthenticated webhook request")
            throw Abort(.unauthorized, reason: "Webhook authentication required")
        }

        do {
            try await oidc.verify(bearer.token)
        } catch let unavailable as FirebaseJWKSUnavailableError {
            // Infrastructure failure, not a bad token: let the caller retry.
            throw unavailable
        } catch {
            request.logger.warning("Webhook OIDC verification failed", metadata: [
                "error": .string(String(describing: error)),
            ])
            throw Abort(.unauthorized, reason: "Webhook authentication failed")
        }

        return try await next.respond(to: request)
    }
}
