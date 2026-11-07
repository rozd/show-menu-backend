import Foundation
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// End-to-end proof that the wire contract is what the server serves: the real `routes(app)`
/// wiring, no emulator or network. Nothing here names a route the code registered by hand;
/// paths and methods come from `openapi.yaml` via the generated `registerHandlers`.
@Suite("Contract routes")
struct ContractRouteTests {

    private func errorCode(_ res: TestingHTTPResponse) throws -> String {
        try res.content.decode(ErrorEnvelope.self).error.code
    }

    @Test("GET /api/v1/health answers {\"status\":\"ok\"}, unauthenticated")
    func health() async throws {
        try await ContractTestApp.with { app in
            try await app.test(.GET, "api/v1/health") { res async throws in
                #expect(res.status == .ok)
                let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: String]
                #expect(json == ["status": "ok"])
            }
        }
    }

    @Test("GET /api/v1/version answers the build info as text")
    func version() async throws {
        try await ContractTestApp.with { app in
            try await app.test(.GET, "api/v1/version") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType)?.hasPrefix("text/plain") == true)
                #expect(res.body.string == Environment.buildInfo)
            }
        }
    }

    @Test("GET /api/v1/plans without a token is a 401 `unauthorized` envelope")
    func plansRequireAuthentication() async throws {
        try await ContractTestApp.with { app in
            try await app.test(.GET, "api/v1/plans") { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
        }
    }

    @Test("a non-admin token on an admin operation is a 403 `forbidden` envelope")
    func plansRequireAdmin() async throws {
        try await ContractTestApp.with { app in
            let token = try ContractTestApp.unsignedToken(admin: false)
            try await app.test(.GET, "api/v1/plans", headers: ContractTestApp.bearer(token)) { res async throws in
                #expect(res.status == .forbidden)
                #expect(try errorCode(res) == "forbidden")
            }
        }
    }

    @Test("a malformed JSON body on POST /api/v1/plans is a 400 `bad_request` envelope")
    func malformedBody() async throws {
        try await ContractTestApp.with { app in
            var headers = ContractTestApp.bearer(try ContractTestApp.unsignedToken(admin: true))
            headers.contentType = .json
            try await app.test(.POST, "api/v1/plans", headers: headers, body: ByteBuffer(string: "{ nope")) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "bad_request")
            }
            // A well-formed object missing required fields is a 400 too (not Vapor's {error,reason}).
            try await app.test(.POST, "api/v1/plans", headers: headers, body: ByteBuffer(string: #"{"SKU":"X"}"#)) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "bad_request")
            }
        }
    }

    @Test("a missing required body is a 400 `bad_request` envelope")
    func missingBody() async throws {
        try await ContractTestApp.with { app in
            let headers = ContractTestApp.bearer(try ContractTestApp.unsignedToken(admin: true))
            try await app.test(.POST, "api/v1/plans", headers: headers) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "bad_request")
            }
        }
    }

    @Test("the old root routes are gone: GET /health and GET /version are 404; so is POST /")
    func legacyRootRoutesAreGone() async throws {
        try await ContractTestApp.with { app in
            try await app.test(.GET, "health") { res async throws in
                #expect(res.status == .notFound)
                #expect(try errorCode(res) == "not_found")
            }
            try await app.test(.GET, "version") { res async in #expect(res.status == .notFound) }
            try await app.test(.POST, "") { res async in #expect(res.status == .notFound) }
            try await app.test(.GET, "api/v1/echo/hello") { res async in #expect(res.status == .notFound) }
        }
    }

    @Test("no route exists that is not a contract operation (all 20 are registered, nothing else)")
    func routeInventory() async throws {
        try await ContractTestApp.with { app in
            let routes = app.routes.all.map { "\($0.method.rawValue) /" + $0.path.map(\.description).joined(separator: "/") }
            #expect(routes.count == 20)
            #expect(routes.allSatisfy { $0.contains("/api/v1/") })
        }
    }

    @Test("the scheduler job is guarded by its own credentials, not a user token")
    func schedulerJobAuth() async throws {
        try await ContractTestApp.with { app in
            let admin = ContractTestApp.bearer(try ContractTestApp.unsignedToken(admin: true))
            try await app.test(.POST, "api/v1/subscriptions/jobs/check-expired", headers: admin) { res async throws in
                #expect(res.status == .unauthorized)
                #expect(try errorCode(res) == "unauthorized")
            }
        }
    }

    @Test("Eventarc webhook: unauthenticated is 401; a delivery without CloudEvents headers is acknowledged")
    func eventarcWebhook() async throws {
        try await ContractTestApp.with { app in
            try await app.test(.POST, "api/v1/events/eventarc") { res async in
                #expect(res.status == .unauthorized)
            }
        }
        try await ContractTestApp.with(
            eventarc: EventarcAuthenticator(oidc: nil, bypassInEmulator: true)
        ) { app in
            try await app.test(.POST, "api/v1/events/eventarc") { res async in
                #expect(res.status == .ok)
            }
            var headers = HTTPHeaders()
            headers.contentType = .json
            try await app.test(.POST, "api/v1/events/eventarc", headers: headers, body: ByteBuffer(string: "{}")) { res async in
                #expect(res.status == .ok)
            }
            // A CloudEvent with an unsupported type is rejected with 400, not acknowledged.
            var ce = headers
            ce.add(name: "ce-specversion", value: "1.0")
            ce.add(name: "ce-type", value: "unsupported.type")
            ce.add(name: "ce-source", value: "//x")
            ce.add(name: "ce-id", value: "1")
            ce.add(name: "ce-time", value: Date().jsISOString)
            try await app.test(.POST, "api/v1/events/eventarc", headers: ce, body: ByteBuffer(string: "{}")) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "bad_request")
            }
        }
    }

    @Test("cancelSubscription: unauthenticated is 401 (not 404); authenticated answers the JSON string \"OK\"")
    func cancelSubscriptionStub() async throws {
        try await ContractTestApp.with { app in
            let path = "api/v1/accounts/a1/subscriptions/s1"
            try await app.test(.DELETE, path) { res async in
                #expect(res.status == .unauthorized)
            }
            let headers = ContractTestApp.bearer(try ContractTestApp.unsignedToken())
            try await app.test(.DELETE, path, headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "\"OK\"")
            }
        }
    }

    @Test("a malformed Idempotency-Key is a 400 on any route, reads included")
    func malformedIdempotencyKey() async throws {
        try await ContractTestApp.with { app in
            var headers = HTTPHeaders()
            headers.add(name: "Idempotency-Key", value: String(repeating: "x", count: 300))
            try await app.test(.GET, "api/v1/health", headers: headers) { res async throws in
                #expect(res.status == .badRequest)
                #expect(try errorCode(res) == "idempotency_key_invalid")
            }
        }
    }

    @Test("buildInfo reads BUILD_* and K_REVISION, with fallbacks")
    func buildInfo() {
        #expect(Environment.buildInfo(in: [:]) == "v0.0.1+local, revision: unknown")
        #expect(Environment.buildInfo(in: [
            "BUILD_BRANCH_NAME": "main", "BUILD_SHORT_SHA": "abc123", "K_REVISION": "svc-00007",
        ]) == "v0.0.1+main-abc123, revision: svc-00007")
    }

    /// `Accept` is ignored (``IgnoreAcceptHeaderMiddleware``): the generated serializer would
    /// otherwise answer 406 *after* the handler ran — after a purchase had committed.
    @Test("an Accept header that excludes the response type is ignored")
    func acceptMismatchIgnored() async throws {
        try await ContractTestApp.with { app in
            var headers = HTTPHeaders()
            headers.add(name: .accept, value: "application/json")
            try await app.test(.GET, "api/v1/version", headers: headers) { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
            }
        }
    }
}
