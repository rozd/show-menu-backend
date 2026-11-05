import Vapor

extension EventarcAuthMiddleware {

    /// Builds the middleware from the process environment.
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
    ) -> EventarcAuthMiddleware {
        if isEmulator {
            return EventarcAuthMiddleware(oidc: nil, bypassInEmulator: true)
        }

        let audience = [environment["EVENTARC_OIDC_AUDIENCE"], environment["SCHEDULER_OIDC_AUDIENCE"]]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let audience else {
            logger.warning("EVENTARC_OIDC_AUDIENCE / SCHEDULER_OIDC_AUDIENCE not set — the webhook (POST /) will reject all callers (user onboarding will not run)")
            return EventarcAuthMiddleware(oidc: nil, bypassInEmulator: false)
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
        return EventarcAuthMiddleware(
            oidc: GoogleOIDCTokenVerifier(audience: audience, allowedEmails: allowed, client: client, logger: logger),
            bypassInEmulator: false
        )
    }
}

extension Application {

    private struct EventarcAuthMiddlewareKey: StorageKey {
        typealias Value = EventarcAuthMiddleware
    }

    /// The webhook auth middleware, built on first use. Tests may assign their own
    /// before `routes(_:)` runs.
    var eventarcAuthMiddleware: EventarcAuthMiddleware {
        get {
            if let existing = storage[EventarcAuthMiddlewareKey.self] {
                return existing
            }
            let middleware = EventarcAuthMiddleware.make(
                isEmulator: gcp.config.environment.isEmulator,
                client: client,
                logger: logger
            )
            storage[EventarcAuthMiddlewareKey.self] = middleware
            return middleware
        }
        set { storage[EventarcAuthMiddlewareKey.self] = newValue }
    }
}
