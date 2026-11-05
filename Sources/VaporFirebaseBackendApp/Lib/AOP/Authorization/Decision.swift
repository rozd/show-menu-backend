//
//  Decision.swift
//  VaporFirebaseBackendApp
//
//  Created by Max Rozdobudko on 6/14/26.
//

/// The outcome of an authorization check produced by an ``Ability``.
///
/// A denial always carries a human-readable `reason` so it can be surfaced in
/// error messages and audit logs — an authorization outcome is never a bare `Bool`.
enum Decision: Sendable, Equatable {
    case allowed
    case denied(reason: String)

    /// `true` when the decision permits the action.
    var isAllowed: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }
}
