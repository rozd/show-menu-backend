import Foundation
import JWT
import Logging
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

@Suite("Firebase ID-token authentication")
struct FirebaseAuthTests {

    static let project = "show-menu-dev"
    static let logger = Logger(label: "test")

    // MARK: Token factories

    private static func claims(
        iss: String = "https://securetoken.google.com/\(project)",
        aud: String = project,
        expiresIn: TimeInterval = 3600,
        sub: String = "uid-1",
        admin: Bool? = nil
    ) -> FirebaseIDToken {
        FirebaseIDToken(
            iss: .init(value: iss),
            aud: .init(value: aud),
            exp: .init(value: Date().addingTimeInterval(expiresIn)),
            sub: .init(value: sub),
            email: "u@example.com",
            admin: admin
        )
    }

    private static func keys() async -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: "test-secret-test-secret-test-secret-0123456789", digestAlgorithm: .sha256)
        return keys
    }

    private static func signed(_ payload: FirebaseIDToken) async throws -> String {
        try await keys().sign(payload)
    }

    /// An emulator-style unsigned token (`alg: none`).
    private static func unsigned(_ payload: FirebaseIDToken) throws -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let body = b64(try JSONEncoder().encode(payload))
        return "\(header).\(body)."
    }

    private static func signedVerifier() async -> FirebaseTokenVerifier {
        FirebaseTokenVerifier(projectID: project, keys: await keys(), logger: logger)
    }

    private static func emulatorVerifier() -> FirebaseTokenVerifier {
        FirebaseTokenVerifier(
            projectID: project, acceptsUnsignedTokens: true, client: UnavailableClient(), logger: logger
        )
    }

    // MARK: Verifier

    @Test("valid signed token verifies and carries the claims")
    func validToken() async throws {
        let token = try await Self.signed(Self.claims(admin: true))
        let verified = try await Self.signedVerifier().verify(token)
        #expect(verified.sub.value == "uid-1")
        #expect(verified.admin == true)
    }

    @Test("expired token is rejected")
    func expired() async throws {
        let token = try await Self.signed(Self.claims(expiresIn: -60))
        await #expect(throws: (any Error).self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("wrong audience is rejected")
    func wrongAudience() async throws {
        let token = try await Self.signed(Self.claims(aud: "other-project"))
        await #expect(throws: FirebaseAuthError.self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("wrong issuer is rejected")
    func wrongIssuer() async throws {
        let token = try await Self.signed(Self.claims(iss: "https://securetoken.google.com/other"))
        await #expect(throws: FirebaseAuthError.self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("empty subject is rejected")
    func emptySubject() async throws {
        let token = try await Self.signed(Self.claims(sub: ""))
        await #expect(throws: FirebaseAuthError.self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("token signed with an unknown key is rejected")
    func badSignature() async throws {
        let other = JWTKeyCollection()
        await other.add(hmac: "different-secret-different-secret-0123456789", digestAlgorithm: .sha256)
        let token = try await other.sign(Self.claims())
        await #expect(throws: (any Error).self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("unsigned token is rejected outside emulator mode")
    func unsignedOutsideEmulator() async throws {
        let token = try Self.unsigned(Self.claims())
        await #expect(throws: (any Error).self) { try await Self.signedVerifier().verify(token) }
    }

    @Test("emulator mode accepts an unsigned token but still checks exp/aud/iss")
    func emulatorUnsigned() async throws {
        let ok = try await Self.emulatorVerifier().verify(Self.unsigned(Self.claims(admin: true)))
        #expect(ok.admin == true)

        await #expect(throws: (any Error).self) {
            try await Self.emulatorVerifier().verify(Self.unsigned(Self.claims(expiresIn: -60)))
        }
        await #expect(throws: FirebaseAuthError.self) {
            try await Self.emulatorVerifier().verify(Self.unsigned(Self.claims(aud: "x")))
        }
        await #expect(throws: FirebaseAuthError.self) {
            try await Self.emulatorVerifier().verify(Self.unsigned(Self.claims(iss: "https://securetoken.google.com/x")))
        }
        await #expect(throws: FirebaseAuthError.self) {
            try await Self.emulatorVerifier().verify("not-a-jwt")
        }
    }

    @Test("JWKS max-age is parsed, defaulting to one hour")
    func maxAge() {
        #expect(FirebaseTokenVerifier.maxAge(from: ["Cache-Control": "public, max-age=19000, must-revalidate"]) == 19000)
        #expect(FirebaseTokenVerifier.maxAge(from: [:]) == 3600)
    }

    @Test("admin claim maps to Role.admin; absent or false does not")
    func principalMapping() {
        #expect(FirebasePrincipal(token: Self.claims(admin: true)).roles == [.admin])
        #expect(FirebasePrincipal(token: Self.claims(admin: false)).roles.isEmpty)
        #expect(FirebasePrincipal(token: Self.claims()).roles.isEmpty)
        #expect(FirebasePrincipal(token: Self.claims(sub: "abc")).id == "abc")
    }

    // MARK: HTTP guards

    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            app.useErrorEnvelope()
            let verifier = await Self.signedVerifier()
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
        try await withApp { app in
            try await app.test(.GET, "api/v1/plans") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
        }
    }

    @Test("invalid bearer token → 401")
    func invalidToken() async throws {
        try await withApp { app in
            try await app.test(.GET, "api/v1/plans", headers: bearer("invalid.jwt.token")) { res async throws in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("expired, wrong-aud and wrong-iss tokens → 401")
    func rejectedTokens() async throws {
        try await withApp { app in
            for payload in [
                Self.claims(expiresIn: -60),
                Self.claims(aud: "other"),
                Self.claims(iss: "https://securetoken.google.com/other"),
            ] {
                let token = try await Self.signed(payload)
                try await app.test(.GET, "api/v1/plans", headers: bearer(token)) { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
        }
    }

    @Test("non-admin on /plans (including unmatched paths) → 403")
    func nonAdminForbidden() async throws {
        try await withApp { app in
            let token = try await Self.signed(Self.claims())
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
        try await withApp { app in
            let token = try await Self.signed(Self.claims(admin: true))
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
        try await withApp { app in
            let token = try await Self.signed(Self.claims(sub: "uid-42"))
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
