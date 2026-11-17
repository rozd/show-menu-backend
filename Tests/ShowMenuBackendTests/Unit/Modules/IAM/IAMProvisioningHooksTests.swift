import Foundation
import Testing
import Passage
import Vapor
@testable import ShowMenuBackend

/// Unit tests for the Passage → IAM provisioning bridge: `didRegister` must
/// announce the new account as `UserCreatedIntegrationEvent` — the payload the
/// existing onboarding pipeline consumes — and must skip (not crash on) an
/// account with no id.
@Suite("IAM Provisioning Hooks")
struct IAMProvisioningHooksTests {

    private struct StubPassageUser: Passage::User {
        var id: String?
        var email: String?
        var phone: String?
        var username: String?
        var passwordHash: String?
        var isAnonymous: Bool = false
        var isEmailVerified: Bool = false
        var isPhoneVerified: Bool = false
        var sessionID: String { id ?? "" }
    }

    private func withRequest(_ body: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(Request(application: app, on: app.eventLoopGroup.any()))
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("didRegister publishes UserCreatedIntegrationEvent with the account id and email")
    func didRegisterPublishes() async throws {
        try await withRequest { request in
            let channel = SpyIntegrationEventChannel()
            let hooks = IAMProvisioningHooks(channel: channel)

            await hooks.didRegister(
                user: StubPassageUser(id: "user-1", email: "alice@example.com"),
                on: request
            )

            let events = await channel.publishedEvents
            #expect(events.count == 1)
            let event = try #require(events.first as? UserCreatedIntegrationEvent)
            #expect(event.userId == "user-1")
            #expect(event.email == "alice@example.com")
        }
    }

    @Test("didRegister without an account id publishes nothing")
    func didRegisterWithoutId() async throws {
        try await withRequest { request in
            let channel = SpyIntegrationEventChannel()
            let hooks = IAMProvisioningHooks(channel: channel)

            await hooks.didRegister(user: StubPassageUser(id: nil), on: request)

            #expect(await channel.publishedEvents.isEmpty)
        }
    }
}
