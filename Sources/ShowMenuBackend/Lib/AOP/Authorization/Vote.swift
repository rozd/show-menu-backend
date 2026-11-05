//
//  Vote.swift
//  ShowMenuBackend
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// A single ``Voter``'s opinion about an authorization question.
///
/// Voters are deliberately allowed to `abstain`: a voter speaks only to the
/// concern it understands and stays silent otherwise. A ``VoteAggregationStrategy``
/// reduces the collected votes into a final ``Decision``.
enum Vote: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case abstain
}
