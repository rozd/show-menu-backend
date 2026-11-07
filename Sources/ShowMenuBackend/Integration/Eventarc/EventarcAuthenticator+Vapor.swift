import Vapor

extension EventarcAuthenticator {

    /// Builds the authenticator from the process environment.
    ///
    /// - Emulator → verification bypassed.
    /// - `EVENTARC_OIDC_AUDIENCE` (fallback `SCHEDULER_OIDC_AUDIENCE`, both name
    ///   this one service) unset → deny-all, with a startup warning.
    /// - `EVENTARC_ALLOWED_SERVICE_ACCOUNTS` (comma-separated) restricts the
    ///   caller's service-account email; empty accepts any Google-signed token
    ///   for the audience (warned).
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isEmulator: Bool,
        client: any Client,
        logger: Logger
    ) -> EventarcAuthenticator {
        if isEmulator {
            return EventarcAuthenticator(oidc: nil, bypassInEmulator: true, logger: logger)
        }

        let audience = [environment["EVENTARC_OIDC_AUDIENCE"], environment["SCHEDULER_OIDC_AUDIENCE"]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let audience else {
            logger.warning("EVENTARC_OIDC_AUDIENCE / SCHEDULER_OIDC_AUDIENCE not set — the webhook (POST /api/v1/events/eventarc) will reject all callers (user onboarding will not run)")
            return EventarcAuthenticator(oidc: nil, bypassInEmulator: false, logger: logger)
        }

        let allowed = Set(
            (environment["EVENTARC_ALLOWED_SERVICE_ACCOUNTS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        if allowed.isEmpty {
            logger.warning("EVENTARC_ALLOWED_SERVICE_ACCOUNTS not set — the webhook accepts any Google-signed OIDC token for this audience; set it to restrict callers")
        }
        return EventarcAuthenticator(
            oidc: GoogleOIDCTokenVerifier(audience: audience, allowedEmails: allowed, client: client, logger: logger),
            bypassInEmulator: false,
            logger: logger
        )
    }
}

extension Application {

    private struct EventarcAuthenticatorKey: StorageKey {
        typealias Value = EventarcAuthenticator
    }

    /// The webhook authenticator, built on first use. Tests may assign their own
    /// before `routes(_:)` runs.
    var eventarcAuthenticator: EventarcAuthenticator {
        get {
            if let existing = storage[EventarcAuthenticatorKey.self] {
                return existing
            }
            let authenticator = EventarcAuthenticator.make(
                isEmulator: gcp.config.environment.isEmulator,
                client: client,
                logger: logger
            )
            storage[EventarcAuthenticatorKey.self] = authenticator
            return authenticator
        }
        set { storage[EventarcAuthenticatorKey.self] = newValue }
    }
}
