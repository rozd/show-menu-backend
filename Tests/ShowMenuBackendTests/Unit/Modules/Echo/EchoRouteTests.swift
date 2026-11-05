import Foundation
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

@Suite("Echo routes")
struct EchoRouteTests {

    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let api = app.grouped("api")
            try api.register(collection: EchoRouteV1(buildInfo: { "v0.0.1+test, revision: r1" }))
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("GET /api/v1/echo/hello returns a JSON string containing Hello")
    func hello() async throws {
        try await withApp { app in
            try await app.test(.GET, "api/v1/echo/hello") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)
                let text = try JSONDecoder().decode(String.self, from: Data(res.body.readableBytesView))
                #expect(text == "Hello from ShowMenuBackend!")
            }
        }
    }

    @Test("GET /api/v1/echo/version returns the build info as text")
    func version() async throws {
        try await withApp { app in
            try await app.test(.GET, "api/v1/echo/version") { res async throws in
                #expect(res.status == .ok)
                #expect(res.body.string == "v0.0.1+test, revision: r1")
            }
        }
    }

    @Test("the old unprefixed /v1/echo path is not served")
    func noLegacyPrefix() async throws {
        try await withApp { app in
            try await app.test(.GET, "v1/echo/hello") { res async throws in
                #expect(res.status == .notFound)
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
}
