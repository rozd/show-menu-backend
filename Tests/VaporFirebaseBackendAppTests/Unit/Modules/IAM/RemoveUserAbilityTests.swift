import Testing
@testable import VaporFirebaseBackendApp

/// Truth table for the worked-example rule:
/// admin may remove any account; the owner may remove their own *active* account;
/// a disabled account is admin-only; everyone else is denied by default.
@Suite("RemoveUserAbility")
struct RemoveUserAbilityTests {
    let ability = RemoveUserAbility()

    private func user(id: String, disabled: Bool = false) -> User {
        User(id: User.Id(rawValue: id), disabled: disabled)
    }

    @Test("admin may remove any account, active or disabled")
    func adminAllowed() {
        let admin = StubPrincipal(id: "admin-1", roles: [.admin])
        #expect(ability.evaluate(principal: admin, subject: user(id: "u-1")) == .allowed)
        #expect(ability.evaluate(principal: admin, subject: user(id: "u-2", disabled: true)) == .allowed)
    }

    @Test("owner may remove their own active account")
    func selfActiveAllowed() {
        let owner = StubPrincipal(id: "u-1")
        #expect(ability.evaluate(principal: owner, subject: user(id: "u-1")) == .allowed)
    }

    @Test("owner may NOT remove their own disabled account (specific reason)")
    func selfDisabledDenied() {
        let owner = StubPrincipal(id: "u-1")
        let decision = ability.evaluate(principal: owner, subject: user(id: "u-1", disabled: true))
        #expect(decision == .denied(reason: "A disabled account can only be removed by an administrator"))
    }

    @Test("a non-admin may not remove someone else's account (default deny)")
    func otherDeniedByDefault() {
        let stranger = StubPrincipal(id: "u-9")
        #expect(ability.evaluate(principal: stranger, subject: user(id: "u-1")) == .denied(reason: "Not authorized"))
    }
}
