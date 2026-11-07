import Vapor

extension SchedulerAuthenticator {

    /// Builds the authenticator from the process environment.
    ///
    /// - Emulator → verification bypassed.
    /// - `SCHEDULER_API_KEY` → enables the `X-Api-Key` path.
    /// - `SCHEDULER_OIDC_AUDIENCE` (the Cloud Run service URL) → enables OIDC;
    ///   `SCHEDULER_ALLOWED_SERVICE_ACCOUNTS` (comma-separated) restricts the caller's
    ///   service-account email (empty accepts any Google-signed token for the audience, warned).
    /// - Neither set → deny-all, with a startup warning.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isEmulator: Bool,
        client: any Client,
        logger: Logger
    ) -> SchedulerAuthenticator {
        if isEmulator {
            return SchedulerAuthenticator(apiKey: nil, oidc: nil, bypassInEmulator: true, logger: logger)
        }

        let apiKey = environment["SCHEDULER_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let audience = environment["SCHEDULER_OIDC_AUDIENCE"].flatMap { $0.isEmpty ? nil : $0 }

        var oidc: GoogleOIDCTokenVerifier?
        if let audience {
            let allowed = Set(
                (environment["SCHEDULER_ALLOWED_SERVICE_ACCOUNTS"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            if allowed.isEmpty {
                logger.warning("SCHEDULER_ALLOWED_SERVICE_ACCOUNTS not set — scheduled endpoints accept any Google-signed OIDC token for this audience; set it to restrict callers")
            }
            oidc = GoogleOIDCTokenVerifier(audience: audience, allowedEmails: allowed, client: client, logger: logger)
        }

        if apiKey == nil && oidc == nil {
            logger.warning("SCHEDULER_OIDC_AUDIENCE / SCHEDULER_API_KEY not set — scheduled endpoints (subscription expiration job) will reject all callers")
        }
        return SchedulerAuthenticator(apiKey: apiKey, oidc: oidc, bypassInEmulator: false, logger: logger)
    }
}

extension Application {

    private struct SchedulerAuthenticatorKey: StorageKey {
        typealias Value = SchedulerAuthenticator
    }

    /// The scheduler authenticator, built on first use. Tests may assign their own before
    /// `routes(_:)` runs.
    var schedulerAuthenticator: SchedulerAuthenticator {
        get {
            if let existing = storage[SchedulerAuthenticatorKey.self] {
                return existing
            }
            let authenticator = SchedulerAuthenticator.make(
                isEmulator: gcp.config.environment.isEmulator,
                client: client,
                logger: logger
            )
            storage[SchedulerAuthenticatorKey.self] = authenticator
            return authenticator
        }
        set { storage[SchedulerAuthenticatorKey.self] = newValue }
    }
}
