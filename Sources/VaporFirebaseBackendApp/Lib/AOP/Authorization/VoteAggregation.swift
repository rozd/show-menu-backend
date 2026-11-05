//
//  VoteAggregation.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Reduces the votes collected from an ``Ability``'s ``Voter``s into a final
/// ``Decision``. Pluggable so the combination policy can vary per ability.
protocol VoteAggregationStrategy: Sendable {
    func decide(votes: [Vote]) -> Decision
}

/// The safe default strategy: **any `deny` wins**, otherwise **any `allow`
/// wins**, otherwise fall back to `defaultDecision` (deny by default).
///
/// This "deny-overrides" ordering means a single objecting voter can veto an
/// action no matter how many others allow it, and that silence (all voters
/// abstain) is treated as "not permitted".
struct DenyOverridesStrategy: VoteAggregationStrategy {
    let defaultDecision: Decision

    init(defaultDecision: Decision = .denied(reason: "Not authorized")) {
        self.defaultDecision = defaultDecision
    }

    func decide(votes: [Vote]) -> Decision {
        for vote in votes {
            if case .deny(let reason) = vote {
                return .denied(reason: reason)
            }
        }
        if votes.contains(.allow) {
            return .allowed
        }
        return defaultDecision
    }
}

extension VoteAggregationStrategy where Self == DenyOverridesStrategy {
    /// Deny-overrides with a default-deny fallback — the recommended default.
    static var denyOverrides: DenyOverridesStrategy { DenyOverridesStrategy() }
}
