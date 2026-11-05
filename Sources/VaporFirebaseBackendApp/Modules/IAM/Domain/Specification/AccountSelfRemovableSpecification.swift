//
//  AccountSelfRemovableSpecification.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// Domain-state rule: an account is eligible for self-service removal only while
/// it is active. A disabled (locked/moderated) account is *not* self-removable —
/// it can be removed only by an administrator.
///
/// This is actor-free domain logic: it speaks only to the state of the `User`,
/// never to who is acting. The principal-aware part composes it inside
/// ``SelfRemovalVoter``.
struct AccountSelfRemovableSpecification: Specification {
    typealias E = User

    func isSatisfied(by entity: User) -> Bool {
        !entity.disabled
    }
}
