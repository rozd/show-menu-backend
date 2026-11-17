import Foundation
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// End-to-end proof that the wire contract is what the server serves: the real wiring, a real
/// Passage login, the in-memory store. Paths and methods come from `openapi.yaml` via the
/// generated `registerHandlers`; nothing here names a route the code registered by hand.
@Suite("Contract routes")
struct ContractRouteTests {

    private func errorCode(_ res: TestingHTTPResponse) throws -> String {
        try res.content.decode(ErrorEnvelope.self).error.code
    }

    private static let injectedTable: [String: Access] = [
        "getCurrentOwner": .authenticated,
        "getOwner": .admin,
    ]

    // MARK: Public operations

    @Test("GET /api/v1/health answers {\"status\":\"ok\"}, unauthenticated and with a garbage bearer")
    func health() async throws {
        try await ContractTestApp.with { app in
            try await app.testing().test(.GET, "api/v1/health") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: String]
                #expect(json == ["status": "ok"])
            }
            try await app.testing().test(.GET, "api/v1/health", headers: ContractTestApp.bearer("garbage")) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("GET /api/v1/version answers the build info as text")
    func version() async throws {
        try await ContractTestApp.with { app in
            try await app.testing().test(.GET, "api/v1/version") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType)?.hasPrefix("text/plain") == true)
                #expect(res.body.string == BuildInfo.current)
            }
        }
    }

    @Test("buildInfo reads BUILD_* and K_REVISION, with fallbacks")
    func buildInfoFallbacks() {
        #expect(buildInfo(in: [:]) == "v0.0.1+local, revision: unknown")
        #expect(buildInfo(in: ["BUILD_BRANCH_NAME": "main"]) == "v0.0.1+main, revision: unknown")
        #expect(buildInfo(in: ["BUILD_BRANCH_NAME": "main", "BUILD_SHORT_SHA": "abc123"]) == "v0.0.1+main-abc123, revision: unknown")
        #expect(buildInfo(in: [
            "BUILD_BRANCH_NAME": "main", "BUILD_SHORT_SHA": "abc123", "K_REVISION": "svc-00007",
        ]) == "v0.0.1+main-abc123, revision: svc-00007")
    }

    // MARK: Fail closed (production table)

    @Test("GET /api/v1/me fails closed in production: 401 envelope with no token and with a valid token")
    func meFailsClosed() async throws {
        try await ContractTestApp.with { app in
            try await app.testing().test(.GET, "api/v1/me") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
            let session = try await ContractTestApp.signIn(app)
            try await app.testing().test(.GET, "api/v1/me", headers: ContractTestApp.bearer(session.accessToken)) { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
        }
    }

    // MARK: Principal seam (injected table)

    @Test("injected table: a valid Passage token reaches the witness (501), no token is 401")
    func authenticatedReachesWitness() async throws {
        try await ContractTestApp.with(accessTable: Self.injectedTable) { app in
            try await app.testing().test(.GET, "api/v1/me") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
            try await app.testing().test(.GET, "api/v1/me", headers: ContractTestApp.bearer("garbage")) { res async throws in
                #expect(res.status == .unauthorized)
            }
            let session = try await ContractTestApp.signIn(app)
            try await app.testing().test(.GET, "api/v1/me", headers: ContractTestApp.bearer(session.accessToken)) { res async throws in
                #expect(res.status == .notImplemented)
                let error = try res.content.decode(ErrorEnvelope.self).error
                #expect(error.code == "not_implemented")
                #expect(error.requestId != nil)
            }
        }
    }

    @Test("injected table: a non-admin token on an admin operation is 403, no token is 401")
    func adminRequiresRole() async throws {
        try await ContractTestApp.with(accessTable: Self.injectedTable) { app in
            let path = "api/v1/businesses/b1/owners/o1"
            try await app.testing().test(.GET, path) { res async throws in
                #expect(res.status == .unauthorized)
            }
            let session = try await ContractTestApp.signIn(app)
            try await app.testing().test(.GET, path, headers: ContractTestApp.bearer(session.accessToken)) { res async throws in
                #expect(res.status == .forbidden)
                #expect(try errorCode(res) == "forbidden")
            }
        }
    }

    // MARK: Edge behaviour

    @Test("a malformed Idempotency-Key is a 400 on any route, reads included")
    func malformedIdempotencyKey() async throws {
        try await ContractTestApp.with { app in
            var headers = HTTPHeaders()
            headers.add(name: "Idempotency-Key", value: String(repeating: "x", count: 300))
            try await app.testing().test(.GET, "api/v1/health", headers: headers) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "idempotency_key_invalid")
            }
        }
    }

    /// `Accept` is ignored (``IgnoreAcceptHeaderMiddleware``): the generated serializer would
    /// otherwise answer 406 *after* the handler ran.
    @Test("an Accept header that excludes the response type is ignored")
    func acceptMismatchIgnored() async throws {
        try await ContractTestApp.with { app in
            var headers = HTTPHeaders()
            headers.add(name: .accept, value: "application/xml")
            try await app.testing().test(.GET, "api/v1/health", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "api/v1/version", headers: headers) { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
            }
        }
    }

    @Test("an unknown path is a 404 envelope")
    func unknownPath() async throws {
        try await ContractTestApp.with { app in
            try await app.testing().test(.GET, "api/v1/nope") { res async throws in
                #expect(res.status == .notFound)
                #expect(try errorCode(res) == "not_found")
            }
        }
    }

    // MARK: Route inventory

    @Test("no hand-written routes: every route is a contract route under /api or one of Passage's")
    func routeInventory() async throws {
        try await ContractTestApp.with { app in
            let paths = app.routes.all.map { "/" + $0.path.map(\.description).joined(separator: "/") }
            for forbidden in ["/health", "/version", "/v1/items", "/v1/users"] {
                #expect(!paths.contains(forbidden), "\(forbidden)")
            }
            let contract = paths.filter { $0.hasPrefix("/api/") }
            let badContract = contract.filter { !$0.hasPrefix("/api/v1/") }
            #expect(badContract.isEmpty)
            // The contract has 102 operations; some share a path, so just require they exist.
            #expect(contract.count >= 100)
            // Passage mounts /auth/* and /me; nothing else is outside the contract.
            let strays = paths.filter { !$0.hasPrefix("/api/") && !$0.hasPrefix("/auth/") && $0 != "/me" }
            #expect(strays.isEmpty)
        }
    }
}
