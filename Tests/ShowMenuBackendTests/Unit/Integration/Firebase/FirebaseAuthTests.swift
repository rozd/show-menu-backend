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

// MARK: - Fixtures

/// An RSA key pair with a key id; can sign tokens and publish its public JWK.
private struct TestKey {
    let kid: String
    let privateKey: JWTKit.Insecure.RSA.PrivateKey

    init(kid: String) throws {
        self.kid = kid
        self.privateKey = try JWTKit.Insecure.RSA.PrivateKey(backing: _RSA.Signing.PrivateKey(keySize: .bits2048))
    }

    func sign(_ payload: FirebaseIDToken, kid override: String? = nil) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(rsa: privateKey, digestAlgorithm: .sha256, kid: JWKIdentifier(string: override ?? kid))
        return try await keys.sign(payload, kid: JWKIdentifier(string: override ?? kid))
    }

    var jwk: [String: String] {
        let primitives = try! privateKey.publicKey.getKeyPrimitives()
        return [
            "kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid,
            "n": primitives.modulus.base64URL, "e": primitives.publicExponent.base64URL,
        ]
    }

    static func jwks(_ keys: TestKey...) -> Data {
        try! JSONSerialization.data(withJSONObject: ["keys": keys.map(\.jwk)])
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

/// A scriptable fake JWKS endpoint that counts fetches.
private final class FakeJWKS: @unchecked Sendable {
    enum Behavior {
        case serve(Data, maxAge: Int?)
        case fail
        case garbage
    }

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _fetchCount = 0
    private let delay: Duration

    init(_ behavior: Behavior, delay: Duration = .zero) {
        _behavior = behavior
        self.delay = delay
    }

    var fetchCount: Int { lock.withLock { _fetchCount } }
    func set(_ behavior: Behavior) { lock.withLock { _behavior = behavior } }

    var fetcher: JWKSFetcher {
        { [self] in
            let behavior = lock.withLock { () -> Behavior in
                _fetchCount += 1
                return _behavior
            }
            if delay > .zero { try await Task.sleep(for: delay) }
            switch behavior {
            case let .serve(data, maxAge):
                var headers = HTTPHeaders()
                if let maxAge { headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=\(maxAge)") }
                return (data, headers)
            case .fail:
                throw FirebaseJWKSUnavailableError(underlying: "HTTP 500")
            case .garbage:
                return (Data("not json".utf8), HTTPHeaders())
            }
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Firebase ID-token authentication")
struct FirebaseAuthTests {

    static let project = "show-menu-dev"
    fileprivate static let logger = Logger(label: "test")

    // MARK: Token factories

    fileprivate static func claims(
        iss: String = "https://securetoken.google.com/\(project)",
        aud: String = project,
        expiresIn: TimeInterval = 3600,
        sub: String = "uid-1",
        admin: Bool? = nil,
        iat: TimeInterval? = -10,
        authTime: TimeInterval? = nil
    ) -> FirebaseIDToken {
        FirebaseIDToken(
            iss: .init(value: iss),
            aud: .init(value: aud),
            exp: .init(value: Date().addingTimeInterval(expiresIn)),
            sub: .init(value: sub),
            email: "u@example.com",
            admin: admin,
            iat: iat.map { .init(value: Date().addingTimeInterval($0)) },
            authTime: authTime.map { Date().addingTimeInterval($0).timeIntervalSince1970 }
        )
    }

    /// An unsigned token (`alg: none`) with the given header kid.
    fileprivate static func unsigned(_ payload: FirebaseIDToken, kid: String? = "k1") throws -> String {
        let kidPart = kid.map { #","kid":"\#($0)""# } ?? ""
        let header = Data(#"{"alg":"none","typ":"JWT"\#(kidPart)}"#.utf8).base64URL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let body = try encoder.encode(payload).base64URL
        return "\(header).\(body)."
    }

    private static func verifier(
        _ server: FakeJWKS, clock: Clock = Clock(), emulator: Bool = false
    ) -> FirebaseTokenVerifier {
        FirebaseTokenVerifier(
            projectID: project,
            acceptsUnsignedTokens: emulator,
            fetcher: server.fetcher,
            now: { clock.now },
            logger: logger
        )
    }

    // MARK: Signed (RS256) path

    @Test("valid RS256 token verifies, selecting the key by kid among several")
    func validToken() async throws {
        let k1 = try TestKey(kid: "k1"), k2 = try TestKey(kid: "k2")
        let server = FakeJWKS(.serve(TestKey.jwks(k1, k2), maxAge: 3600))
        let verifier = Self.verifier(server)
        for key in [k1, k2] {
            let verified = try await verifier.verify(key.sign(Self.claims(admin: true)))
            #expect(verified.sub.value == "uid-1")
            #expect(verified.admin == true)
        }
    }

    @Test("token signed by another key under a known kid is rejected")
    func otherKey() async throws {
        let k1 = try TestKey(kid: "k1"), attacker = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        let token = try await attacker.sign(Self.claims())
        await #expect(throws: (any Error).self) { try await verifier.verify(token) }
    }

    @Test("unknown kid is rejected")
    func unknownKid() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        let token = try await k1.sign(Self.claims(), kid: "nope")
        await #expect(throws: (any Error).self) { try await verifier.verify(token) }
    }

    @Test("alg none is rejected outside emulator mode")
    func algNone() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        let token = try Self.unsigned(Self.claims())
        await #expect(throws: FirebaseAuthError.malformedToken) { try await verifier.verify(token) }
    }

    @Test("HS256 signed with the public key as the secret is rejected (algorithm confusion)")
    func algorithmConfusion() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        let hmac = JWTKeyCollection()
        await hmac.add(hmac: HMACKey(from: k1.privateKey.publicKey.pemRepresentation), digestAlgorithm: .sha256, kid: "k1")
        let token = try await hmac.sign(Self.claims(), kid: "k1")
        await #expect(throws: FirebaseAuthError.malformedToken) { try await verifier.verify(token) }
    }

    @Test("RS256 token without a kid is rejected")
    func missingKid() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        let keys = JWTKeyCollection()
        await keys.add(rsa: k1.privateKey, digestAlgorithm: .sha256)
        let token = try await keys.sign(Self.claims())
        await #expect(throws: FirebaseAuthError.malformedToken) { try await verifier.verify(token) }
    }

    @Test("expired, wrong audience, wrong issuer and empty subject are rejected")
    func claimFailures() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        await #expect(throws: (any Error).self) { try await verifier.verify(k1.sign(Self.claims(expiresIn: -60))) }
        await #expect(throws: FirebaseAuthError.self) { try await verifier.verify(k1.sign(Self.claims(aud: "other"))) }
        await #expect(throws: FirebaseAuthError.self) {
            try await verifier.verify(k1.sign(Self.claims(iss: "https://securetoken.google.com/other")))
        }
        await #expect(throws: FirebaseAuthError.self) { try await verifier.verify(k1.sign(Self.claims(sub: ""))) }
    }

    @Test("iat / auth_time in the future are rejected; within the leeway they pass")
    func futureTimes() async throws {
        let k1 = try TestKey(kid: "k1")
        let verifier = Self.verifier(FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600)))
        await #expect(throws: FirebaseAuthError.issuedInFuture) {
            try await verifier.verify(k1.sign(Self.claims(iat: 600)))
        }
        await #expect(throws: FirebaseAuthError.issuedInFuture) {
            try await verifier.verify(k1.sign(Self.claims(authTime: 600)))
        }
        _ = try await verifier.verify(k1.sign(Self.claims(iat: 10, authTime: 10)))
        _ = try await verifier.verify(k1.sign(Self.claims(iat: nil)))
    }

    // MARK: JWKS cache

    @Test("two verifications share one JWKS fetch; expiry triggers a refetch")
    func cacheReuse() async throws {
        let k1 = try TestKey(kid: "k1")
        let server = FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 300))
        let clock = Clock()
        let verifier = Self.verifier(server, clock: clock)
        let token = try await k1.sign(Self.claims())
        _ = try await verifier.verify(token)
        _ = try await verifier.verify(token)
        #expect(server.fetchCount == 1)
        clock.advance(301)
        _ = try await verifier.verify(token)
        #expect(server.fetchCount == 2)
    }

    @Test("concurrent verifications on a cold cache coalesce into one fetch")
    func coalescing() async throws {
        let k1 = try TestKey(kid: "k1")
        let server = FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600), delay: .milliseconds(100))
        let verifier = Self.verifier(server)
        let token = try await k1.sign(Self.claims())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try await verifier.verify(token) }
            }
            try await group.waitForAll()
        }
        #expect(server.fetchCount == 1)
    }

    @Test("max-age is parsed, defaulting to an hour and clamped to [60s, 24h]")
    func maxAge() {
        func age(_ value: String?) -> TimeInterval {
            FirebaseTokenVerifier.maxAge(from: value.map { ["Cache-Control": $0] } ?? [:])
        }
        #expect(age("public, max-age=19000, must-revalidate") == 19000)
        #expect(age(nil) == 3600)
        #expect(age("max-age=5") == 60)
        #expect(age("max-age=99999999") == 86400)
    }

    @Test("a failed refresh serves the stale keys")
    func staleOnRefreshFailure() async throws {
        let k1 = try TestKey(kid: "k1")
        let server = FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 60))
        let clock = Clock()
        let verifier = Self.verifier(server, clock: clock)
        let token = try await k1.sign(Self.claims())
        _ = try await verifier.verify(token)

        server.set(.fail)
        clock.advance(120)
        _ = try await verifier.verify(token)           // refresh fails → stale keys
        #expect(server.fetchCount == 2)
        _ = try await verifier.verify(token)           // within the stale retry interval: no hammering
        #expect(server.fetchCount == 2)
    }

    @Test("JWKS fetch failure or garbage with nothing cached is an unavailable error, not an auth failure")
    func jwksUnavailable() async throws {
        let k1 = try TestKey(kid: "k1")
        let token = try await k1.sign(Self.claims())
        for behavior in [FakeJWKS.Behavior.fail, .garbage] {
            let verifier = Self.verifier(FakeJWKS(behavior))
            await #expect(throws: FirebaseJWKSUnavailableError.self) { try await verifier.verify(token) }
        }
    }

    // MARK: Emulator path

    @Test("emulator mode accepts an unsigned token but still checks exp/aud/iss/iat")
    func emulatorUnsigned() async throws {
        let verifier = Self.verifier(FakeJWKS(.fail), emulator: true)
        let ok = try await verifier.verify(Self.unsigned(Self.claims(admin: true), kid: nil))
        #expect(ok.admin == true)

        await #expect(throws: (any Error).self) { try await verifier.verify(Self.unsigned(Self.claims(expiresIn: -60))) }
        await #expect(throws: FirebaseAuthError.self) { try await verifier.verify(Self.unsigned(Self.claims(aud: "x"))) }
        await #expect(throws: FirebaseAuthError.self) {
            try await verifier.verify(Self.unsigned(Self.claims(iss: "https://securetoken.google.com/x")))
        }
        await #expect(throws: FirebaseAuthError.issuedInFuture) { try await verifier.verify(Self.unsigned(Self.claims(iat: 600))) }
        await #expect(throws: FirebaseAuthError.self) { try await verifier.verify("not-a-jwt") }
    }

    @Test("emulator payload with epoch-second integers is read as real times (not 2001-relative)")
    func emulatorEpochSeconds() async throws {
        func b64(_ s: String) -> String { Data(s.utf8).base64URL }
        let now = Int(Date().timeIntervalSince1970)
        func token(exp: Int, iat: Int) -> String {
            let body = #"{"iss":"https://securetoken.google.com/show-menu-dev","aud":"show-menu-dev","sub":"u","iat":\#(iat),"auth_time":\#(iat),"exp":\#(exp)}"#
            return "\(b64(#"{"alg":"none"}"#)).\(b64(body))."
        }
        let verifier = Self.verifier(FakeJWKS(.fail), emulator: true)
        _ = try await verifier.verify(token(exp: now + 3600, iat: now))
        await #expect(throws: (any Error).self) { try await verifier.verify(token(exp: now - 60, iat: now - 3600)) }
        await #expect(throws: FirebaseAuthError.issuedInFuture) { try await verifier.verify(token(exp: now + 7200, iat: now + 3600)) }
    }

    @Test("admin claim maps to Role.admin; absent or false does not")
    func principalMapping() {
        #expect(FirebasePrincipal(token: Self.claims(admin: true)).roles == [.admin])
        #expect(FirebasePrincipal(token: Self.claims(admin: false)).roles.isEmpty)
        #expect(FirebasePrincipal(token: Self.claims()).roles.isEmpty)
        #expect(FirebasePrincipal(token: Self.claims(sub: "abc")).id == "abc")
    }

    // MARK: HTTP guards

    private func withApp(
        server: FakeJWKS, _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.useErrorEnvelope()
            let verifier = Self.verifier(server)
            let authenticated = app.grouped("api").grouped(FirebaseAuthMiddleware(verifier: verifier))
            let admin = authenticated.grouped(RequireAdminMiddleware())
            try admin.register(collection: PlansGuardRouteV1())
            authenticated.get("v1", "whoami") { _ async -> String in
                RequestContext.principal?.id ?? "none"
            }
            authenticated.get("v1", "metadata") { req async -> String in
                CommandMetadata(req: req).userId ?? "none"
            }
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func bearer(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }

    private func errorCode(_ res: TestingHTTPResponse) throws -> String {
        try res.content.decode(ErrorEnvelope.self).error.code
    }

    @Test("missing Authorization header → 401 envelope")
    func missingHeader() async throws {
        let k1 = try TestKey(kid: "k1")
        try await withApp(server: FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600))) { app in
            try await app.test(.GET, "api/v1/plans") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
        }
    }

    @Test("garbage, expired, wrong-aud, wrong-iss, other-key and alg-none tokens → 401")
    func rejectedTokens() async throws {
        let k1 = try TestKey(kid: "k1"), attacker = try TestKey(kid: "k1")
        try await withApp(server: FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600))) { app in
            let tokens = [
                "invalid.jwt.token",
                try await k1.sign(Self.claims(expiresIn: -60)),
                try await k1.sign(Self.claims(aud: "other")),
                try await k1.sign(Self.claims(iss: "https://securetoken.google.com/other")),
                try await attacker.sign(Self.claims()),
                try Self.unsigned(Self.claims()),
            ]
            for token in tokens {
                try await app.test(.GET, "api/v1/plans", headers: bearer(token)) { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
        }
    }

    @Test("JWKS outage → 503 envelope, not 401")
    func jwksOutage() async throws {
        let k1 = try TestKey(kid: "k1")
        let token = try await k1.sign(Self.claims())
        try await withApp(server: FakeJWKS(.fail)) { app in
            try await app.test(.GET, "api/v1/plans", headers: bearer(token)) { res async throws in
                #expect(res.status == .serviceUnavailable)
                #expect(try errorCode(res) == "service_unavailable")
            }
        }
    }

    @Test("non-admin on /plans (including unmatched paths) → 403")
    func nonAdminForbidden() async throws {
        let k1 = try TestKey(kid: "k1")
        try await withApp(server: FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600))) { app in
            let token = try await k1.sign(Self.claims())
            for path in ["api/v1/plans", "api/v1/plans/non-existent-plan"] {
                try await app.test(.GET, path, headers: bearer(token)) { res async throws in
                    #expect(res.status == .forbidden)
                    #expect(try errorCode(res) == "forbidden")
                }
            }
        }
    }

    @Test("admin passes the guard: stub list is 200, unmatched path is 404")
    func adminAllowed() async throws {
        let k1 = try TestKey(kid: "k1")
        try await withApp(server: FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600))) { app in
            let token = try await k1.sign(Self.claims(admin: true))
            try await app.test(.GET, "api/v1/plans", headers: bearer(token)) { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string == "[]")
            }
            try await app.test(.GET, "api/v1/plans/non-existent-plan", headers: bearer(token)) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("principal is bound for the request and feeds CommandMetadata.userId")
    func principalBound() async throws {
        let k1 = try TestKey(kid: "k1")
        try await withApp(server: FakeJWKS(.serve(TestKey.jwks(k1), maxAge: 3600))) { app in
            let token = try await k1.sign(Self.claims(sub: "uid-42"))
            try await app.test(.GET, "api/v1/whoami", headers: bearer(token)) { res async throws in
                #expect(res.body.string == "uid-42")
            }
            try await app.test(.GET, "api/v1/metadata", headers: bearer(token)) { res async throws in
                #expect(res.body.string == "uid-42")
            }
        }
    }

    @Test("RequireAdminMiddleware fails closed (401) without a principal")
    func adminGuardFailsClosed() async throws {
        let app = try await Application.make(.testing)
        app.useErrorEnvelope()
        app.grouped(RequireAdminMiddleware()).get("x") { _ async -> String in "ok" }
        try await app.test(.GET, "x") { res async throws in
            #expect(res.status == .unauthorized)
        }
        try await app.asyncShutdown()
    }
}
