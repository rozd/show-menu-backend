//
//  RemoveUserAbility.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Authorizes removal of a `User` account — the named entry point call sites use.
///
/// Rule (deny-overrides): an administrator may remove any account; the account
/// owner may remove their own account *unless it is disabled* (a disabled account
/// is admin-only). Everyone else is denied by default.
struct RemoveUserAbility: Ability {
    private let inner: VotingAbility<User>

    init(strategy: any VoteAggregationStrategy = .denyOverrides) {
        self.inner = VotingAbility(
            voters: [
                AnyVoter(AdminRoleVoter()),
                AnyVoter(SelfRemovalVoter()),
            ],
            strategy: strategy
        )
    }

    func evaluate(principal: any Principal, subject: User) -> Decision {
        inner.evaluate(principal: principal, subject: subject)
    }
}
