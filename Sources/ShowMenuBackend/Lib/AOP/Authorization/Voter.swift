//
//  Voter.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// A small, reusable unit of authorization logic that returns a ``Vote`` over a
/// `(principal, subject)` pair.
///
/// Voters are the composition mechanism *underneath* an ``Ability`` — call sites
/// never talk to voters directly. A voter should answer only the one concern it
/// understands and `abstain` otherwise.
protocol Voter: Sendable {
    associatedtype Subject: Sendable

    func vote(principal: any Principal, subject: Subject) -> Vote
}

/// A type-erased ``Voter`` over a fixed `Subject`, so voters of different concrete
/// types can be aggregated by an ``Ability``.
///
/// Mirrors the type-erasing combinator structs used by `Specification`.
struct AnyVoter<Subject: Sendable>: Voter {
    private let _vote: @Sendable (any Principal, Subject) -> Vote

    init<V: Voter>(_ voter: V) where V.Subject == Subject {
        self._vote = { principal, subject in
            voter.vote(principal: principal, subject: subject)
        }
    }

    func vote(principal: any Principal, subject: Subject) -> Vote {
        _vote(principal, subject)
    }
}
