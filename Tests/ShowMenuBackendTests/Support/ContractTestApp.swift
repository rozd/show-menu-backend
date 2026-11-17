import Foundation
import Passage
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

/// Boots the real wiring against the in-memory SQLite store: the trace + error-envelope
/// middleware, Passage (real registration / login), and the contract routes.
///
/// No network, no external service. The access table can be injected to exercise the
/// authenticated / admin paths while the production table has only the two public operations.
enum ContractTestApp {

    static let password = "correct-horse-battery"

    /// Mirrors `entrypoint` + `configure(_:)` for the pieces under test.
    static func make(accessTable: [String: Access]? = nil) async throws -> Application {
        let app = try await Application.make(.testing)
        do {
            app.middleware.use(TraceMiddleware(), at: .beginning)
            app.middleware.use(IdempotencyKeyMiddleware())
            app.useErrorEnvelope()
            try await configureFluentStore(app)
            await configureIntegrationEvents(app)
            try await configurePassage(app)
            if let accessTable {
                try app.registerContractHandlers(accessTable: accessTable)
            } else {
                try routes(app)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        return app
    }

    /// Runs `body` against a fresh app and always shuts it down.
    static func with(accessTable: [String: Access]? = nil, _ body: (Application) async throws -> Void) async throws {
        let app = try await make(accessTable: accessTable)
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    struct Session {
        let accessToken: String
        let userId: String
    }

    private struct AuthResponse: Decodable {
        struct UserInfo: Decodable { let id: String }
        let accessToken: String
        let user: UserInfo
    }

    /// Registers a user through Passage's own `/auth/register` and logs in.
    static func signIn(_ app: Application, username: String = "alice") async throws -> Session {
        let credentials = ["username": username, "password": password, "confirmPassword": password]
        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
            try req.content.encode(credentials)
        }) { res async in
            #expect(res.status == .ok)
        }
        var response: AuthResponse?
        try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
            try req.content.encode(credentials)
        }) { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        }
        let auth = try #require(response)
        return Session(accessToken: auth.accessToken, userId: auth.user.id)
    }

    static func bearer(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }
}

/// Thread-safe mutable box for capturing values from `@Sendable` closures in tests.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
