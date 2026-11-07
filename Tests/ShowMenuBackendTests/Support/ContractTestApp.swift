import Foundation
import HTTPTypes
import Logging
import Vapor
@testable import ShowMenuBackend

/// Boots the real wiring (`routes(app)` → `registerContractHandlers()`), with the auth
/// collaborators injected so no emulator, network or Firestore is needed. Handlers are never
/// reached by tests using this helper unless they bring their own dependency overrides.
enum ContractTestApp {

    static let projectID = "show-menu-dev"
    static let logger = Logger(label: "test")

    /// A verifier that accepts unsigned (`alg: none`) tokens, as in emulator mode.
    static func unsignedVerifier() -> FirebaseTokenVerifier {
        FirebaseTokenVerifier(
            projectID: projectID,
            acceptsUnsignedTokens: true,
            fetcher: { throw FirebaseJWKSUnavailableError(underlying: "no network in tests") },
            now: { Date() },
            logger: logger
        )
    }

    /// An unsigned Firebase ID token for `sub`, optionally with the `admin` claim.
    static func unsignedToken(sub: String = "uid-1", admin: Bool = false) throws -> String {
        let claims = FirebaseIDToken(
            iss: .init(value: "https://securetoken.google.com/\(projectID)"),
            aud: .init(value: projectID),
            exp: .init(value: Date().addingTimeInterval(3600)),
            sub: .init(value: sub),
            email: "u@example.com",
            admin: admin ? true : nil,
            iat: .init(value: Date().addingTimeInterval(-10)),
            authTime: nil
        )
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return "\(b64(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))).\(b64(try encoder.encode(claims)))."
    }

    static func bearer(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }

    /// An app with the error envelope and the real contract routes registered. Unset
    /// authenticators default to deny-all (scheduler / eventarc) and the unsigned verifier.
    static func make(
        verifier: FirebaseTokenVerifier? = nil,
        scheduler: SchedulerAuthenticator? = nil,
        eventarc: EventarcAuthenticator? = nil
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        app.useErrorEnvelope()
        // As in `configure(_:)`: the global source of truth for `Idempotency-Key`.
        app.middleware.use(IdempotencyKeyMiddleware())
        app.firebaseTokenVerifier = verifier ?? unsignedVerifier()
        app.schedulerAuthenticator = scheduler ?? SchedulerAuthenticator(apiKey: nil, oidc: nil, bypassInEmulator: false, logger: logger)
        app.eventarcAuthenticator = eventarc ?? EventarcAuthenticator(oidc: nil, bypassInEmulator: false, logger: logger)
        try routes(app)
        return app
    }

    /// Replaces dependencies resolved through `app.deps` (witnesses resolve them per request).
    static func override(_ app: Application, _ overrides: Partial<any Application.Dependencies>) {
        guard let root = app.deps as? Application.CompositionRoot else {
            preconditionFailure("app.deps is not a CompositionRoot")
        }
        root.resolver.override(overrides)
    }

    /// Runs `body` against a fresh app and always shuts it down.
    static func with(
        verifier: FirebaseTokenVerifier? = nil,
        scheduler: SchedulerAuthenticator? = nil,
        eventarc: EventarcAuthenticator? = nil,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await make(verifier: verifier, scheduler: scheduler, eventarc: eventarc)
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
