import Foundation
import Testing
import Vapor
import VaporTesting
@testable import ShowMenuBackend

@Suite("Subscription cancel route")
struct SubscriptionCancelRouteTests {

    /// Rejects every request, standing in for `FirebaseAuthMiddleware` without a valid token.
    private struct DenyAll: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            throw Abort(.unauthorized)
        }
    }

    private func withApp(guarded: Bool, _ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let api = app.grouped("api")
            let group = guarded ? api.grouped(DenyAll()) : api
            try group.register(collection: SubscriptionCancelRouteV1())
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("DELETE answers a JSON \"OK\" like the Node stub")
    func answersOK() async throws {
        try await withApp(guarded: false) { app in
            try await app.test(.DELETE, "api/v1/accounts/a1/subscriptions/s1") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "\"OK\"")
            }
        }
    }

    @Test("the route exists, so the auth guard answers 401 rather than 404")
    func guardedRouteIs401() async throws {
        try await withApp(guarded: true) { app in
            try await app.test(.DELETE, "api/v1/accounts/a1/subscriptions/s1") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
