//
//  SelfRemovalVoter.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Governs self-service account removal.
///
/// - Abstains when the principal is not the account owner (admins are handled by
///   ``AdminRoleVoter``).
/// - For the owner, composes ``AccountSelfRemovableSpecification`` (domain state):
///   an active account may be self-removed, but a disabled account may not — that
///   is an explicit `deny` so a locked account cannot self-delete to escape.
struct SelfRemovalVoter: Voter {
    private let selfRemovable = AccountSelfRemovableSpecification()

    func vote(principal: any Principal, subject: User) -> Vote {
        guard principal.id == subject.id.rawValue else {
            return .abstain
        }
        return selfRemovable.isSatisfied(by: subject)
            ? .allow
            : .deny(reason: "A disabled account can only be removed by an administrator")
    }
}
