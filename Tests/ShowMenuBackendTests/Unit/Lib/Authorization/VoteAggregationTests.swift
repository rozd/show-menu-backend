import Testing
@testable import ShowMenuBackend

@Suite("DenyOverridesStrategy")
struct DenyOverridesStrategyTests {
    let sut = DenyOverridesStrategy()

    @Test("any deny overrides any allow")
    func denyBeatsAllow() {
        let decision = sut.decide(votes: [.allow, .deny(reason: "nope"), .allow])
        #expect(decision == .denied(reason: "nope"))
    }

    @Test("allow wins when there is no deny")
    func allowBeatsAbstain() {
        let decision = sut.decide(votes: [.abstain, .allow, .abstain])
        #expect(decision == .allowed)
    }

    @Test("all abstain falls back to default deny")
    func allAbstainDefaultsDeny() {
        let decision = sut.decide(votes: [.abstain, .abstain])
        #expect(decision == .denied(reason: "Not authorized"))
    }

    @Test("empty votes falls back to default deny")
    func emptyDefaultsDeny() {
        #expect(sut.decide(votes: []) == .denied(reason: "Not authorized"))
    }

    @Test("the first deny reason is reported")
    func firstDenyReason() {
        let decision = sut.decide(votes: [.deny(reason: "first"), .deny(reason: "second")])
        #expect(decision == .denied(reason: "first"))
    }

    @Test("a configurable default decision is used when all abstain")
    func customDefault() {
        let lenient = DenyOverridesStrategy(defaultDecision: .allowed)
        #expect(lenient.decide(votes: [.abstain]) == .allowed)
    }

    @Test("convenience .denyOverrides matches the default initializer")
    func convenienceFactory() {
        let strategy: any VoteAggregationStrategy = .denyOverrides
        #expect(strategy.decide(votes: [.abstain]) == .denied(reason: "Not authorized"))
        #expect(strategy.decide(votes: [.deny(reason: "x"), .allow]) == .denied(reason: "x"))
    }
}
