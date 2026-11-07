import Foundation
import HTTPTypes
import Logging
import Vapor

/// Authenticates the machine-to-machine caller of a scheduled job (`checkExpiredSubscriptions`).
///
/// Accepts **either**
/// - a Google-signed OIDC identity token in `Authorization: Bearer …` (how Cloud Scheduler
///   authenticates: audience = the service URL, issuer Google and, when configured, an
///   allow-listed service-account email — all checked by ``GoogleOIDCTokenVerifier``), **or**
/// - an `X-Api-Key` header equal to `SCHEDULER_API_KEY` (local runs and a shared-secret fallback).
///
/// **Emulator:** verification is skipped, like ``EventarcAuthenticator`` (the emulator-mode e2e
/// test calls the job without credentials). **Unconfigured (non-emulator):** with neither a key
/// nor a verifier every request is denied — secure by default. A JWKS outage is a 503 (the
/// scheduler retries), not a 401. Neither the key nor a token is ever logged.
///
/// `authenticate(headers:)` completes verification **before** the caller runs the job, and never
/// wraps it: an error from the job itself propagates as itself, never as a 401 (commit b249fdc).
struct SchedulerAuthenticator: Sendable {

    /// The `X-Api-Key` header name.
    static let apiKeyHeader = HTTPField.Name("X-Api-Key")!

    /// `SCHEDULER_API_KEY`; `nil` or empty disables the header path.
    let apiKey: String?

    /// Verifies the Google-signed OIDC token; `nil` when unconfigured.
    let oidc: GoogleOIDCTokenVerifier?

    /// Skip verification entirely (emulator only).
    let bypassInEmulator: Bool

    let logger: Logger

    init(apiKey: String?, oidc: GoogleOIDCTokenVerifier?, bypassInEmulator: Bool = false, logger: Logger = Logger(label: "scheduler-auth")) {
        self.apiKey = apiKey
        self.oidc = oidc
        self.bypassInEmulator = bypassInEmulator
        self.logger = logger
    }

    /// Returns normally when the caller is authenticated; throws 401 (or the JWKS outage) otherwise.
    func authenticate(headers: HTTPFields) async throws {
        if bypassInEmulator {
            return
        }

        if let apiKey, !apiKey.isEmpty,
           let provided = headers[Self.apiKeyHeader],
           Self.constantTimeEquals(provided, apiKey) {
            return
        }

        if let oidc, let token = headers.bearerToken {
            do {
                try await oidc.verify(token)
                return
            } catch let unavailable as FirebaseJWKSUnavailableError {
                // Infrastructure failure, not a bad token: let the scheduler retry.
                throw unavailable
            } catch {
                logger.warning("Scheduler OIDC verification failed", metadata: [
                    "error": .string(String(describing: error)),
                ])
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
