//
//  AdminRoleVoter.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Allows the action when the principal holds the administrator role; otherwise
/// abstains — it has nothing to say about non-admins, leaving room for another
/// voter (e.g. ``SelfRemovalVoter``) to speak.
struct AdminRoleVoter: Voter {
    func vote(principal: any Principal, subject: User) -> Vote {
        principal.roles.contains(.admin) ? .allow : .abstain
    }
}

extension Role {
    /// Administrator role: may manage any user account.
    ///
    /// `Lib` defines the `Role` type; this concrete value is a module-level
    /// authorization semantic and therefore lives with the code that checks it.
    static let admin = Role(rawValue: "admin")
}
