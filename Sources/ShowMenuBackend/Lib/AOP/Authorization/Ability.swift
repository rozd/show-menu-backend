//
//  Ability.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// The named entry point for a single authorization decision (one action).
///
/// An ability is principal-aware — it answers "may *this* `principal` perform the
/// action this type represents on *this* `subject`?" The action is encoded by the
/// conforming type, so the method takes only `(principal, subject)`. Call sites
/// talk to abilities, never to ``Voter``s directly.
///
/// An ability is either a direct check or — more commonly — an aggregation of
/// ``Voter``s reduced by a ``VoteAggregationStrategy`` (see ``VotingAbility``).
protocol Ability: Sendable {
    associatedtype Subject: Sendable

    func evaluate(principal: any Principal, subject: Subject) -> Decision
}

/// An ``Ability`` implemented as an aggregation of ``Voter``s reduced by a
/// ``VoteAggregationStrategy``. Concrete abilities typically wrap one of these.
struct VotingAbility<Subject: Sendable>: Ability {
    let voters: [AnyVoter<Subject>]
    let strategy: any VoteAggregationStrategy

    init(
        voters: [AnyVoter<Subject>],
        strategy: any VoteAggregationStrategy = .denyOverrides
    ) {
        self.voters = voters
        self.strategy = strategy
    }

    func evaluate(principal: any Principal, subject: Subject) -> Decision {
        let votes = voters.map { $0.vote(principal: principal, subject: subject) }
        return strategy.decide(votes: votes)
    }
}
