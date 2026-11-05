import Testing
@testable import VaporFirebaseBackendApp

/// Verifies that ``VotingAbility`` erases heterogeneous voters via ``AnyVoter``
/// and reduces their votes through the injected strategy.
@Suite("VotingAbility")
struct VotingAbilityTests {
    struct Doc: Sendable { let ownerId: String }

    struct AllowVoter: Voter {
        func vote(principal: any Principal, subject: Doc) -> Vote { .allow }
    }
    struct DenyVoter: Voter {
        func vote(principal: any Principal, subject: Doc) -> Vote { .deny(reason: "blocked") }
    }
    struct AbstainVoter: Voter {
        func vote(principal: any Principal, subject: Doc) -> Vote { .abstain }
    }

    @Test("deny-overrides: a single deny vetoes any allow")
    func denyWins() {
        let ability = VotingAbility<Doc>(voters: [AnyVoter(AllowVoter()), AnyVoter(DenyVoter())])
        let decision = ability.evaluate(principal: StubPrincipal(), subject: Doc(ownerId: "x"))
        #expect(decision == .denied(reason: "blocked"))
    }

    @Test("deny-overrides: allow wins over abstain")
    func allowWins() {
        let ability = VotingAbility<Doc>(voters: [AnyVoter(AbstainVoter()), AnyVoter(AllowVoter())])
        #expect(ability.evaluate(principal: StubPrincipal(), subject: Doc(ownerId: "x")) == .allowed)
    }

    @Test("no voters falls back to default deny")
    func noVoters() {
        let ability = VotingAbility<Doc>(voters: [])
        let decision = ability.evaluate(principal: StubPrincipal(), subject: Doc(ownerId: "x"))
        #expect(decision == .denied(reason: "Not authorized"))
    }
}
