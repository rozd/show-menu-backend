//
//  PassagePrincipal.swift
//  ShowMenuBackend
//
//  The Principal a Passage-authenticated caller acts as.
//

import Passage

/// Security identity of a caller authenticated by Passage.
///
/// `id` is the Passage account id — the same value the IAM module uses as its
/// `User.Id` — and `roles` come from the IAM `User` record rather than from the
/// token, so a role change takes effect on the caller's next request instead of
/// at token expiry. Built by ``PassagePrincipalResolver``; downstream Policy
/// Enforcement Points only ever see the `Principal` protocol.
struct PassagePrincipal: Principal {
    let id: String
    let roles: Set<Role>
}

extension Passage::User {

    /// The Passage account id in the string form shared with IAM's `User.Id`.
    /// `nil` only for an account that was never persisted.
    var identifierString: String? {
        id.map { String(describing: $0) }
    }
}
