import Testing
@testable import VaporFirebaseBackendApp

@Suite("Decision & Vote")
struct DecisionTests {
    @Test("isAllowed reflects the case")
    func isAllowed() {
        #expect(Decision.allowed.isAllowed)
        #expect(!Decision.denied(reason: "x").isAllowed)
    }

    @Test("denied equality includes the reason")
    func deniedEquality() {
        #expect(Decision.denied(reason: "a") == Decision.denied(reason: "a"))
        #expect(Decision.denied(reason: "a") != Decision.denied(reason: "b"))
        #expect(Decision.allowed != Decision.denied(reason: "a"))
    }

    @Test("vote equality includes the reason")
    func voteEquality() {
        #expect(Vote.deny(reason: "a") != Vote.deny(reason: "b"))
        #expect(Vote.allow == Vote.allow)
        #expect(Vote.abstain != Vote.allow)
    }
}
