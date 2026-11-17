import Foundation
import Testing
import Passage
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// End-to-end tests for the Passage authentication wiring: register → login →
/// call a protected route with the bearer token.
///
/// Unlike the Postgres suite next door, these need **no external service**: with
/// nothing configured the Fluent adapter picks in-memory SQLite for the app's
/// store, so the whole flow runs wherever `swift test` runs — and against the
/// *real* store, IAM's `users` table included.
///
/// Registration uses a **username** identifier: login requires a verified
/// identifier for email/phone, and the template ships no `EmailDelivery`.
///
/// **Single-table proof**: after register, a read through IAM's lens on the shared
/// table returns the SAME row Passage inserted — no event round-trip needed. The
/// protected endpoint used here is Passage's own `GET /me`; HTTP routes proper come
/// from the OpenAPI contract.
@Suite("Passage Auth Flow")
struct PassageAuthFlowTests {

    /// Mirrors `configure(_:)` for the pieces under test.
    private func withPassageApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configureFluentStore(app)
            await configureIntegrationEvents(app)
            try await configurePassage(app)
            try routes(app)
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private struct AuthUserResponse: Codable {
        struct UserInfo: Codable {
            let id: String
        }
        let accessToken: String
        let user: UserInfo
    }

    private let credentials: [String: String] = [
        "username": "alice",
        "password": "correct-horse-battery",
        "confirmPassword": "correct-horse-battery",
    ]

    @Test("register → login → bearer request returns the same user row (single table)")
    func registerLoginProtected() async throws {
        try await withPassageApp { app in
            // Protected endpoints fail closed without a token.
            try await app.testing().test(.GET, "me") { res async in
                #expect(res.status == .unauthorized)
            }

            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(credentials)
            }) { res async in
                #expect(res.status == .ok)
            }

            var authenticated: AuthUserResponse?
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(credentials)
            }) { res async throws in
                #expect(res.status == .ok)
                authenticated = try res.content.decode(AuthUserResponse.self)
            }

            let auth = try #require(authenticated)

            // The bearer token opens the protected endpoint.
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.accessToken)
            }) { res async in
                #expect(res.status == .ok)
            }

            // Read the very row Passage inserted through IAM's lens. The
            // registration hook's integration event found it already present and
            // early-returned — no sync involved.
            let users = FluentUserDataSource(
                transaction: .direct(database: app.deps.appDatabase),
                logger: app.logger
            )
            let model = try #require(try await users.fetch(byId: auth.user.id))
            // Passage inserted this row (no display_name/roles/photo_url).
            #expect(model.id == auth.user.id)
            #expect(model.roles == nil || model.roles?.isEmpty == true)
            // Username registration does not populate email.
            #expect(model.email == nil)

            // A garbage token is rejected before reaching any handler.
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: "not-a-jwt")
            }) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("login with a wrong password is rejected")
    func wrongPassword() async throws {
        try await withPassageApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(credentials)
            }) { res async in
                #expect(res.status == .ok)
            }

            var wrong = credentials
            wrong["password"] = "wrong-password"
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(wrong)
            }) { res async in
                #expect(res.status != .ok)
            }
        }
    }
}
