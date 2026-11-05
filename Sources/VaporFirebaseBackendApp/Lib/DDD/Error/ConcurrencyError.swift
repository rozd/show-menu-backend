//
//  ConcurrencyError.swift
//  VaporFirebaseBackendApp
//
//  Raised when an optimistic-concurrency check-and-set fails.
//

import Foundation

/// Raised when an optimistic-concurrency check-and-set fails: the stored version
/// of an aggregate no longer matches the version the caller loaded, because
/// another writer committed in between.
///
/// Detected at the write/commit (inside the `UnitOfWork` transaction) and
/// surfaced through the `CommandHandler` — never swallowed. Map it at the edge to
/// `409 Conflict` (an internal stale write) or `412 Precondition Failed`
/// (a stale `If-Match` precondition).
enum ConcurrencyError: Error, Equatable, LocalizedError {

    /// `expected` is the token the aggregate was loaded with; `actual` is the
    /// token currently stored. `entity`/`id` identify the conflicting aggregate.
    case versionConflict(entity: String, id: String, expected: Version, actual: Version)

    var errorDescription: String? {
        switch self {
        case let .versionConflict(entity, id, expected, actual):
            return "Version conflict on \(entity)(\(id)): expected \(expected), found \(actual)"
        }
    }
}
