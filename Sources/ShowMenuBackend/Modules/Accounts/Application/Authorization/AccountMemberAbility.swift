/// What an account-membership decision is made about: the account and whether the
/// principal has an `accounts/{id}/permissions/{uid}` document on it. The document
/// is read by the PEP (the use case) before the ability is consulted, because an
/// ``Ability`` is synchronous and I/O-free.
struct AccountMembership: Sendable, Equatable {
    let account: Account
    let hasPermissionDocument: Bool
}

/// May the principal act on this account (roadmap bug 9: Node never checked)?
///
/// Rule (deny-overrides, default deny): an administrator, the account's creator,
/// or any user holding a permission document on it.
struct AccountMemberAbility: Ability {
    private let inner: VotingAbility<AccountMembership>

    init(strategy: any VoteAggregationStrategy = .denyOverrides) {
        self.inner = VotingAbility(
            voters: [
                AnyVoter(AccountAdminVoter()),
                AnyVoter(AccountCreatorVoter()),
                AnyVoter(AccountPermissionVoter()),
            ],
            strategy: strategy
        )
    }

    func evaluate(principal: any Principal, subject: AccountMembership) -> Decision {
        inner.evaluate(principal: principal, subject: subject)
    }
}
