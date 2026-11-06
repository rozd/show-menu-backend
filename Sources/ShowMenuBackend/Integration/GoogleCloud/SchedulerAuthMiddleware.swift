import Foundation
import Vapor

/// Authenticates the machine-to-machine caller of a scheduled job (`POST .../jobs/*`).
///
/// Accepts **either**
/// - a Google-signed OIDC identity token in `Authorization: Bearer …` (how Cloud Scheduler
///   authenticates: audience = the service URL, issuer Google and, when configured, an
///   allow-listed service-account email — all checked by ``GoogleOIDCTokenVerifier``), **or**
/// - an `X-Api-Key` header equal to `SCHEDULER_API_KEY` (local runs and a shared-secret fallback).
///
/// **Emulator:** verification is skipped, like ``EventarcAuthMiddleware`` (the emulator-mode e2e
/// test calls the job without credentials). **Unconfigured (non-emulator):** with neither a key
/// nor a verifier every request is denied — secure by default. A JWKS outage is a 503 (the
/// scheduler retries), not a 401. Neither the key nor a token is ever logged.
struct SchedulerAuthMiddleware: AsyncMiddleware {

    /// `SCHEDULER_API_KEY`; `nil` or empty disables the header path.
    let apiKey: String?

    /// Verifies the Google-signed OIDC token; `nil` when unconfigured.
    let oidc: GoogleOIDCTokenVerifier?

    /// Skip verification entirely (emulator only).
    let bypassInEmulator: Bool

    init(apiKey: String?, oidc: GoogleOIDCTokenVerifier?, bypassInEmulator: Bool = false) {
        self.apiKey = apiKey
        self.oidc = oidc
        self.bypassInEmulator = bypassInEmulator
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if bypassInEmulator {
            return try await next.respond(to: request)
        }

        if let apiKey, !apiKey.isEmpty,
           let provided = request.headers.first(name: "X-Api-Key"),
           Self.constantTimeEquals(provided, apiKey) {
            return try await next.respond(to: request)
        }

        if let oidc, let bearer = request.headers.bearerAuthorization {
            var verified = false
            do {
                try await oidc.verify(bearer.token)
                verified = true
            } catch let unavailable as FirebaseJWKSUnavailableError {
                // Infrastructure failure, not a bad token: let the scheduler retry.
                throw unavailable
            } catch {
                request.logger.warning("Scheduler OIDC verification failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
            }
            // Outside the `do`: an error from the job itself must propagate as itself,
            // never be logged as a verification failure and turned into a 401.
            if verified {
                return try await next.respond(to: request)
            }
        }

        throw Abort(.unauthorized, reason: "Scheduler authentication required")
    }

    /// Length-independent comparison of two secrets (no early exit on the first differing byte).
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
