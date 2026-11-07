import CryptoExtras
import Foundation
import JWT
import JWTKit
import Logging
import NIOHTTP1
import Testing
import HTTPTypes
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// The scheduled job endpoints accept a Cloud Scheduler OIDC token or `X-Api-Key`; everything
/// else is a 401 (and an unconfigured service denies all).
@Suite("Scheduler authentication (Google OIDC / X-Api-Key)")
struct SchedulerAuthenticatorTests {

    static let audience = "https://show-menu-backend-123.us-central1.run.app"
    static let scheduler = "scheduler@show-menu-dev.iam.gserviceaccount.com"
    static let apiKey = "local-secret-key"

    // MARK: Fixtures

    private struct TestKey {
        let kid: String
        let privateKey: JWTKit.Insecure.RSA.PrivateKey

        init(kid: String) throws {
            self.kid = kid
            self.privateKey = try JWTKit.Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        }

        func sign(_ payload: GoogleOIDCToken) async throws -> String {
            let id = JWKIdentifier(string: kid)
            let keys = JWTKeyCollection()
            await keys.add(rsa: privateKey, digestAlgorithm: .sha256, kid: id)
            return try await keys.sign(payload, kid: id)
        }

        var jwksData: Data {
            let primitives = try! privateKey.publicKey.getKeyPrimitives()
            let jwk: [String: String] = [
                "kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid,
                "n": primitives.modulus.base64URL, "e": primitives.publicExponent.base64URL,
            ]
            return try! JSONSerialization.data(withJSONObject: ["keys": [jwk]])
        }
    }

    private static func claims(
        aud: String = audience, email: String? = scheduler, expiresIn: TimeInterval = 3600
    ) -> GoogleOIDCToken {
        GoogleOIDCToken(
            iss: .init(value: "https://accounts.google.com"),
            aud: .init(value: aud),
            exp: .init(value: Date().addingTimeInterval(expiresIn)),
            email: email,
            emailVerified: true
        )
    }

    private static func authenticator(
        trusting key: TestKey?, allowedEmails: Set<String> = [], apiKey: String? = nil, jwksFails: Bool = false
    ) -> SchedulerAuthenticator {
        let fetcher: JWKSFetcher = {
            if jwksFails { throw FirebaseJWKSUnavailableError(underlying: "HTTP 500") }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
            return (key?.jwksData ?? Data(#"{"keys":[]}"#.utf8), headers)
        }
        return SchedulerAuthenticator(
            apiKey: apiKey,
            oidc: key == nil ? nil : GoogleOIDCTokenVerifier(
                audience: audience, allowedEmails: allowedEmails, fetcher: fetcher, logger: Logger(label: "test")
            ),
            logger: Logger(label: "test")
        )
    }

    /// Kept as a thin wrapper so each test reads as "given this authenticator, ...".
    private func withApp(_ authenticator: SchedulerAuthenticator, _ body: (SchedulerAuthenticator) async throws -> Void) async throws {
        try await body(authenticator)
    }

    /// Runs the authenticator on the given credentials and answers the HTTP status the contract
    /// would produce: `.ok` when authenticated, else the error envelope's status.
    private func post(_ auth: SchedulerAuthenticator, token: String? = nil, apiKey: String? = nil) async throws -> HTTPStatus {
        var headers = HTTPFields()
        if let token { headers[.authorization] = "Bearer \(token)" }
        if let apiKey { headers[SchedulerAuthenticator.apiKeyHeader] = apiKey }
        do {
            try await auth.authenticate(headers: headers)
            return .ok
        } catch {
            return HTTPErrorMapping.map(error).status
        }
    }

    private func post(_ app: SchedulerAuthenticator, signedBy key: TestKey, _ claims: GoogleOIDCToken = claims()) async throws -> HTTPStatus {
        try await post(app, token: try await key.sign(claims))
    }

    // MARK: OIDC

    @Test("a valid Cloud Scheduler token passes, also with the service account on the allow-list")
    func validToken() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: key)) { app in
            let status1 = try await post(app, signedBy: key)
            #expect(status1 == .ok)
        }
        try await withApp(Self.authenticator(trusting: key, allowedEmails: [Self.scheduler])) { app in
            let status2 = try await post(app, signedBy: key)
            #expect(status2 == .ok)
        }
    }

    @Test("a wrong audience is 401")
    func badAudience() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: key)) { app in
            let status3 = try await post(app, signedBy: key, Self.claims(aud: "https://someone-else.run.app"))
            #expect(status3 == .unauthorized)
        }
    }

    @Test("a service account outside the allow-list is 401")
    func badServiceAccount() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: key, allowedEmails: ["only@x.iam.gserviceaccount.com"])) { app in
            let status4 = try await post(app, signedBy: key)
            #expect(status4 == .unauthorized)
            let status5 = try await post(app, signedBy: key, Self.claims(email: nil))
            #expect(status5 == .unauthorized)
        }
    }

    @Test("an expired token, a forged signature and garbage are 401")
    func badTokens() async throws {
        let trusted = try TestKey(kid: "k1")
        let attacker = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: trusted)) { app in
            let status6 = try await post(app, signedBy: trusted, Self.claims(expiresIn: -60))
            #expect(status6 == .unauthorized)
            let status7 = try await post(app, signedBy: attacker)
            #expect(status7 == .unauthorized)
            let status8 = try await post(app, token: "not.a.jwt")
            #expect(status8 == .unauthorized)
        }
    }

    @Test("a JWKS outage is 503, not 401")
    func jwksOutage() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: key, jwksFails: true)) { app in
            let status9 = try await post(app, signedBy: key)
            #expect(status9 == .serviceUnavailable)
        }
    }

    @Test("an error thrown by the job behind a valid token keeps its own status, not 401")
    func jobErrorIsNotAuthFailure() async throws {
        let key = try TestKey(kid: "k1")
        let access = ContractAccessMiddleware(
            bearer: FirebaseBearerAuthenticator(
                verifier: FirebaseTokenVerifier(
                    projectID: "p", acceptsUnsignedTokens: false, fetcher: { throw FirebaseJWKSUnavailableError(underlying: "x") },
                    now: { Date() }, logger: Logger(label: "test")
                ),
                logger: Logger(label: "test")
            ),
            scheduler: Self.authenticator(trusting: key),
            eventarc: EventarcAuthenticator(oidc: nil, bypassInEmulator: false)
        )
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(try await key.sign(Self.claims()))"
        let request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/v1/subscriptions/jobs/check-expired", headerFields: headers)
        do {
            _ = try await access.intercept(
                request, body: nil, metadata: .init(),
                operationID: "checkExpiredSubscriptions"
            ) { _, _, _ in throw Abort(.badGateway, reason: "query requires an index") }
            Issue.record("expected the job error to propagate")
        } catch let error as Abort {
            #expect(error.status == .badGateway)
        }
    }

    // MARK: API key

    @Test("the right X-Api-Key passes; a wrong or missing one is 401")
    func apiKey() async throws {
        try await withApp(Self.authenticator(trusting: nil, apiKey: Self.apiKey)) { app in
            let status10 = try await post(app, apiKey: Self.apiKey)
            #expect(status10 == .ok)
            let status11 = try await post(app, apiKey: "nope")
            #expect(status11 == .unauthorized)
            let status12 = try await post(app, apiKey: Self.apiKey + "x")
            #expect(status12 == .unauthorized)
            let status13 = try await post(app)
            #expect(status13 == .unauthorized)
        }
    }

    @Test("either mechanism is enough when both are configured")
    func either() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.authenticator(trusting: key, apiKey: Self.apiKey)) { app in
            let status14 = try await post(app, apiKey: Self.apiKey)
            #expect(status14 == .ok)
            let status15 = try await post(app, signedBy: key)
            #expect(status15 == .ok)
            // a wrong key does not poison a valid token
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(try await key.sign(Self.claims()))"
            headers[SchedulerAuthenticator.apiKeyHeader] = "wrong"
            var status = HTTPStatus.ok
            do { try await app.authenticate(headers: headers) } catch { status = HTTPErrorMapping.map(error).status }
            #expect(status == .ok)
        }
    }

    @Test("an empty configured key never matches an empty header")
    func emptyKey() async throws {
        try await withApp(Self.authenticator(trusting: nil, apiKey: "")) { app in
            let status16 = try await post(app, apiKey: "")
            #expect(status16 == .unauthorized)
            let status17 = try await post(app)
            #expect(status17 == .unauthorized)
        }
    }

    @Test("an unconfigured middleware denies every request")
    func unconfigured() async throws {
        try await withApp(SchedulerAuthenticator(apiKey: nil, oidc: nil)) { app in
            let status18 = try await post(app)
            #expect(status18 == .unauthorized)
            let status19 = try await post(app, apiKey: Self.apiKey)
            #expect(status19 == .unauthorized)
        }
    }

    @Test("constantTimeEquals compares whole strings")
    func constantTime() {
        #expect(SchedulerAuthenticator.constantTimeEquals("abc", "abc"))
        #expect(!SchedulerAuthenticator.constantTimeEquals("abc", "abd"))
        #expect(!SchedulerAuthenticator.constantTimeEquals("abc", "abcd"))
        #expect(!SchedulerAuthenticator.constantTimeEquals("", "a"))
    }

    // MARK: Emulator and configuration

    @Test("the emulator bypass lets an unauthenticated request through")
    func emulatorBypass() async throws {
        try await withApp(SchedulerAuthenticator(apiKey: nil, oidc: nil, bypassInEmulator: true)) { app in
            let status20 = try await post(app)
            #expect(status20 == .ok)
        }
    }

    @Test("make(): emulator bypasses, nothing set denies and warns, key and audience build the pieces")
    func factory() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }

        let emulator = SchedulerAuthenticator.make(environment: [:], isEmulator: true, client: app.client, logger: logger)
        #expect(emulator.bypassInEmulator && emulator.oidc == nil && emulator.apiKey == nil)

        let unconfigured = SchedulerAuthenticator.make(environment: [:], isEmulator: false, client: app.client, logger: logger)
        #expect(!unconfigured.bypassInEmulator && unconfigured.oidc == nil && unconfigured.apiKey == nil)
        #expect(capture.entries.contains { $0.message.contains("SCHEDULER_OIDC_AUDIENCE") })

        let blank = SchedulerAuthenticator.make(
            environment: ["SCHEDULER_OIDC_AUDIENCE": "", "SCHEDULER_API_KEY": ""],
            isEmulator: false, client: app.client, logger: logger
        )
        #expect(blank.oidc == nil && blank.apiKey == nil)

        let configured = SchedulerAuthenticator.make(
            environment: [
                "SCHEDULER_OIDC_AUDIENCE": Self.audience,
                "SCHEDULER_ALLOWED_SERVICE_ACCOUNTS": " a@x.com , b@x.com ",
                "SCHEDULER_API_KEY": Self.apiKey,
            ],
            isEmulator: false, client: app.client, logger: logger
        )
        #expect(!configured.bypassInEmulator && configured.oidc != nil && configured.apiKey == Self.apiKey)
        // The secret is never logged.
        #expect(!capture.entries.contains { $0.message.contains(Self.apiKey) })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
