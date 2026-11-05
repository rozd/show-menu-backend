import CryptoExtras
import Foundation
import JWT
import JWTKit
import Logging
import NIOHTTP1
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// The webhook (`POST /`) is the only unauthenticated-by-token entry into user
/// removal, so outside the emulator a missing or wrong Google OIDC token must be
/// a 401 — before any CloudEvent is parsed.
@Suite("Eventarc webhook authentication (Google OIDC)")
struct EventarcAuthMiddlewareTests {

    static let audience = "https://show-menu-backend-123.us-central1.run.app"
    static let forwarder = "forwarder@show-menu-dev.iam.gserviceaccount.com"

    // MARK: Fixtures

    private struct TestKey {
        let kid: String
        let privateKey: JWTKit.Insecure.RSA.PrivateKey

        init(kid: String) throws {
            self.kid = kid
            self.privateKey = try JWTKit.Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
        }

        func sign(_ payload: GoogleOIDCToken, kid override: String? = nil) async throws -> String {
            let id = JWKIdentifier(string: override ?? kid)
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
        iss: String = "https://accounts.google.com",
        aud: String = audience,
        email: String? = forwarder,
        emailVerified: Bool? = true,
        expiresIn: TimeInterval = 3600
    ) -> GoogleOIDCToken {
        GoogleOIDCToken(
            iss: .init(value: iss),
            aud: .init(value: aud),
            exp: .init(value: Date().addingTimeInterval(expiresIn)),
            email: email,
            emailVerified: emailVerified
        )
    }

    private static func middleware(
        trusting key: TestKey?,
        allowedEmails: Set<String> = [],
        jwksFails: Bool = false
    ) -> EventarcAuthMiddleware {
        let fetcher: JWKSFetcher = {
            if jwksFails { throw FirebaseJWKSUnavailableError(underlying: "HTTP 500") }
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
            return (key?.jwksData ?? Data(#"{"keys":[]}"#.utf8), headers)
        }
        return EventarcAuthMiddleware(
            oidc: GoogleOIDCTokenVerifier(
                audience: audience, allowedEmails: allowedEmails, fetcher: fetcher, logger: Logger(label: "test")
            ),
            bypassInEmulator: false
        )
    }

    /// Serves `POST /` behind the middleware, answering 200 when auth passes.
    private func withApp(
        _ middleware: EventarcAuthMiddleware, _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.useErrorEnvelope()
            app.grouped(middleware).post { _ async -> HTTPStatus in .ok }
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func post(_ app: Application, token: String?) async throws -> HTTPStatus {
        var headers = HTTPHeaders()
        if let token { headers.bearerAuthorization = .init(token: token) }
        var status = HTTPStatus.internalServerError
        try await app.testing().test(.POST, "", headers: headers) { res async in status = res.status }
        return status
    }

    private func post(_ app: Application, signedBy key: TestKey, _ claims: GoogleOIDCToken = claims(), kid: String? = nil) async throws -> HTTPStatus {
        let token = try await key.sign(claims, kid: kid)
        return try await post(app, token: token)
    }

    // MARK: Outside the emulator

    @Test("a valid forwarder token passes")
    func validToken() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key)) { app in
            let status = try await post(app, signedBy: key)
            #expect(status == .ok)
        }
    }

    @Test("an allow-listed service account passes")
    func allowListed() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key, allowedEmails: [Self.forwarder])) { app in
            let status = try await post(app, signedBy: key)
            #expect(status == .ok)
        }
    }

    @Test("a missing Authorization header is 401")
    func missingToken() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key)) { app in
            let status = try await post(app, token: nil)
            #expect(status == .unauthorized)
        }
    }

    @Test("a garbage bearer token is 401")
    func garbageToken() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key)) { app in
            let status = try await post(app, token: "not.a.jwt")
            #expect(status == .unauthorized)
        }
    }

    @Test("a token signed by an untrusted key (same kid) is 401")
    func forgedSignature() async throws {
        let trusted = try TestKey(kid: "k1")
        let attacker = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: trusted)) { app in
            let status = try await post(app, signedBy: attacker)
            #expect(status == .unauthorized)
        }
    }

    @Test("a token with an unknown kid is 401")
    func unknownKid() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key)) { app in
            let status = try await post(app, signedBy: key, kid: "other")
            #expect(status == .unauthorized)
        }
    }

    @Test("wrong audience, wrong issuer and expiry are all 401")
    func claimFailures() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key)) { app in
            for claims in [
                Self.claims(aud: "https://someone-else.run.app"),
                Self.claims(iss: "https://evil.example.com"),
                Self.claims(expiresIn: -60),
            ] {
                let status = try await post(app, signedBy: key, claims)
                #expect(status == .unauthorized)
            }
        }
    }

    @Test("a service account outside the allow-list is 401")
    func notAllowListed() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key, allowedEmails: ["only@x.iam.gserviceaccount.com"])) { app in
            let status = try await post(app, signedBy: key)
            #expect(status == .unauthorized)
        }
    }

    @Test("an allow-listed email that Google marks unverified is 401")
    func allowListedButUnverified() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key, allowedEmails: [Self.forwarder])) { app in
            let status = try await post(app, signedBy: key, Self.claims(emailVerified: false))
            #expect(status == .unauthorized)
        }
    }

    @Test("a JWKS outage is 503, not 401")
    func jwksOutage() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(Self.middleware(trusting: key, jwksFails: true)) { app in
            let status = try await post(app, signedBy: key)
            #expect(status == .serviceUnavailable)
        }
    }

    @Test("an unconfigured middleware (no audience) denies every request")
    func unconfigured() async throws {
        let key = try TestKey(kid: "k1")
        try await withApp(EventarcAuthMiddleware(oidc: nil, bypassInEmulator: false)) { app in
            let anonymous = try await post(app, token: nil)
            #expect(anonymous == .unauthorized)
            let signed = try await post(app, signedBy: key)
            #expect(signed == .unauthorized)
        }
    }

    // MARK: Emulator and configuration

    @Test("the emulator bypass lets an unauthenticated request through")
    func emulatorBypass() async throws {
        try await withApp(EventarcAuthMiddleware(oidc: nil, bypassInEmulator: true)) { app in
            let status = try await post(app, token: nil)
            #expect(status == .ok)
        }
    }

    @Test("make(): emulator bypasses, missing audience denies, audience builds a verifier")
    func factory() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let logger = Logger(label: "test")

        let emulator = EventarcAuthMiddleware.make(environment: [:], isEmulator: true, client: app.client, logger: logger)
        #expect(emulator.bypassInEmulator && emulator.oidc == nil)

        let unconfigured = EventarcAuthMiddleware.make(environment: [:], isEmulator: false, client: app.client, logger: logger)
        #expect(!unconfigured.bypassInEmulator && unconfigured.oidc == nil)

        let blank = EventarcAuthMiddleware.make(
            environment: ["EVENTARC_OIDC_AUDIENCE": ""], isEmulator: false, client: app.client, logger: logger
        )
        #expect(blank.oidc == nil)

        let configured = EventarcAuthMiddleware.make(
            environment: ["SCHEDULER_OIDC_AUDIENCE": Self.audience, "EVENTARC_ALLOWED_SERVICE_ACCOUNTS": " a@x.com , b@x.com "],
            isEmulator: false, client: app.client, logger: logger
        )
        #expect(!configured.bypassInEmulator && configured.oidc != nil)
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
