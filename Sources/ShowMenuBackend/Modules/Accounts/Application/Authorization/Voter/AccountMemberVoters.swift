/// Allows an administrator; abstains for everyone else.
struct AccountAdminVoter: Voter {
    func vote(principal: any Principal, subject: AccountMembership) -> Vote {
        principal.roles.contains(.admin) ? .allow : .abstain
    }
}

/// Allows the account's creator (`accounts/{id}.creator`); abstains otherwise.
struct AccountCreatorVoter: Voter {
    func vote(principal: any Principal, subject: AccountMembership) -> Vote {
        subject.account.creator == principal.id ? .allow : .abstain
    }
}

/// Allows a principal that has a permission document on the account; abstains otherwise.
struct AccountPermissionVoter: Voter {
    func vote(principal: any Principal, subject: AccountMembership) -> Vote {
        subject.hasPermissionDocument ? .allow : .abstain
    }
}
