import HTTPTypes
import Logging
import Vapor

/// Authenticates the caller of the Eventarc webhook (`handleEventarcEvent`).
///
/// The gen-1 forwarders (`cloud-functions/auth-forwarder`, later the Firestore
/// forwarder) request a Google-signed OIDC identity token from the metadata
/// server with the Cloud Run service URL as audience and send it as
/// `Authorization: Bearer …`. This verifies it (issuer Google,
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
struct EventarcAuthenticator: Sendable {

    /// Verifies the Google-signed OIDC token; `nil` when unconfigured.
    let oidc: GoogleOIDCTokenVerifier?

    /// Skip verification entirely (emulator only).
    let bypassInEmulator: Bool

    let logger: Logger

    init(oidc: GoogleOIDCTokenVerifier?, bypassInEmulator: Bool, logger: Logger = Logger(label: "eventarc-auth")) {
        self.oidc = oidc
        self.bypassInEmulator = bypassInEmulator
        self.logger = logger
    }

    /// Returns normally when the caller is authenticated; throws 401 (or the JWKS outage) otherwise.
    func authenticate(headers: HTTPFields) async throws {
        if bypassInEmulator {
            return
        }

        guard let oidc, let token = headers.bearerToken else {
            logger.warning("Rejected unauthenticated webhook request")
            throw Abort(.unauthorized, reason: "Webhook authentication required")
        }

        do {
            try await oidc.verify(token)
        } catch let unavailable as FirebaseJWKSUnavailableError {
            // Infrastructure failure, not a bad token: let the caller retry.
            throw unavailable
        } catch {
            logger.warning("Webhook OIDC verification failed", metadata: [
                "error": .string(String(describing: error)),
            ])
            throw Abort(.unauthorized, reason: "Webhook authentication failed")
        }
    }
}
