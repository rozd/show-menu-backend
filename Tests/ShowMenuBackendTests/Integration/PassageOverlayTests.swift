import Foundation
import Testing
import Passage
import SQLKit
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// Tests specific to Passage overlay mode S1: a single `users` table with two
/// Fluent lenses (Passage and IAM), verified by cascade deletes and column isolation.
///
/// These tests prove that:
/// 1. Foreign key cascades work (SQLite FK pragma enabled).
/// 2. Each lens safely touches only its own columns.
@Suite("Passage Overlay Mode")
struct PassageOverlayTests {

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

    /// Rows in one of Passage's dependent tables referencing the given user.
    private func dependentRows(_ sql: any SQLDatabase, table: String, userId: String) async throws -> Int {
        try await sql.raw("SELECT COUNT(*) AS row_count FROM \(ident: table) WHERE user_id = \(bind: userId)")
            .first()?
            .decode(column: "row_count", as: Int.self) ?? 0
    }

    @Test("cascade delete: removing a user cascades to dependent tables")
    func cascadeDelete() async throws {
        try await withPassageApp { app in
            // Register and login to create a refresh token.
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
            let userId = auth.user.id

            // Registration wrote the identifier row; login minted a refresh token.
            let sql = try FluentTransaction.direct(database: app.deps.appDatabase).sql
            #expect(try await dependentRows(sql, table: "identifiers", userId: userId) == 1)
            #expect(try await dependentRows(sql, table: "refresh_tokens", userId: userId) >= 1)

            // Delete the user row through IAM's lens (what a self-removal ends up doing).
            let users = FluentUserDataSource(
                transaction: .direct(database: app.deps.appDatabase),
                logger: app.logger
            )
            try await users.delete(byIds: [userId])

            // The FK cascade wiped the dependent rows with the user row. SQLite
            // enforces foreign keys here, so a non-cascading delete would have
            // failed outright rather than orphaning them.
            #expect(try await dependentRows(sql, table: "identifiers", userId: userId) == 0)
            #expect(try await dependentRows(sql, table: "refresh_tokens", userId: userId) == 0)

            // The still-valid bearer token now dead-ends inside Passage's own
            // authenticator: `account.user(for:)` misses the deleted row and
            // throws `AuthenticationError.userNotFound`, which Passage maps to
            // 404 — the request never reaches the guard or the controller.
            try await app.testing().test(.GET, "me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.accessToken)
            }) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("column isolation: Passage and IAM lens coexist safely on shared table")
    func columnIsolation() async throws {
        try await withPassageApp { app in
            // Register via Passage username.
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(credentials)
            }) { res async in
                #expect(res.status == .ok)
            }

            // Get the user ID from login.
            var authenticated: AuthUserResponse?
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(credentials)
            }) { res async throws in
                #expect(res.status == .ok)
                authenticated = try res.content.decode(AuthUserResponse.self)
            }

            let auth = try #require(authenticated)
            let userId = auth.user.id

            // Read the user through IAM's lens — Passage just inserted it with a
            // username, no display_name.
            let lens = FluentUserDataSource(
                transaction: .direct(database: app.deps.appDatabase),
                logger: app.logger
            )
            let inserted = try #require(try await lens.fetch(byId: userId))
            #expect(inserted.displayName == nil)
            // Username registration does not populate email.
            #expect(inserted.email == nil, "username registration does not populate email")

            // Passage's credential columns, read outside both lenses.
            let sql = try FluentTransaction.direct(database: app.deps.appDatabase).sql
            let before = try await sql.raw(
                "SELECT password_hash FROM users WHERE id = \(bind: userId)"
            ).first()
            let hashBefore = try #require(try before?.decode(column: "password_hash", as: String?.self))

            // An IAM-lens write: the SQL-layer update writes EVERY IAM coding key
            // (nil as explicit NULL included) — and must still leave the columns
            // it does not declare untouched.
            let users = FluentUserDataSource(
                transaction: .direct(database: app.deps.appDatabase),
                logger: app.logger
            )
            let fetched = try #require(try await users.fetch(byId: userId))
            try await users.update(model: UserModel(
                id: userId,
                phone: fetched.phone,
                username: fetched.username,
                displayName: "Alice",
                phoneVerified: fetched.phoneVerified ?? false,
                version: fetched.version,
                createdAt: fetched.createdAt
            ))

            let after = try await sql.raw(
                "SELECT password_hash, username FROM users WHERE id = \(bind: userId)"
            ).first()
            #expect(try after?.decode(column: "password_hash", as: String?.self) == hashBefore)
            #expect(try after?.decode(column: "username", as: String?.self) == "alice")

            // …and the IAM write itself landed through its own lens.
            let updated = try #require(try await users.fetch(byId: userId))
            #expect(updated.displayName == "Alice")
        }
    }
}
