//
//  Version.swift
//  VaporFirebaseBackendApp
//
//  An opaque optimistic-concurrency token carried by an `AggregateRoot`.
//

/// An opaque optimistic-concurrency token for an aggregate.
///
/// The domain treats `Version` as an opaque value: it is loaded with the
/// aggregate, carried back on write, and may be surfaced at the edge (e.g. as an
/// HTTP `ETag`) — but domain code never inspects or hand-increments it. Each
/// persistence store binds the token to a native mechanism and owns advancing it:
///
/// - **A monotonic integer counter** — what the Firestore adapter uses today (an
///   integer `version` document field) and what a SQL store would bind to a
///   `version` column (see ``VersionedModel``).
/// - **A store-native token** — a row timestamp, an `xmin` system column, a
///   document `updateTime` — could be bound instead without touching the domain.
///
/// `.none` means "not yet bound to a stored value" — a brand-new aggregate, or a
/// document written before versioning existed. Two `.none` tokens compare equal,
/// which lets pre-existing documents adopt optimistic concurrency on their first
/// write with no data migration.
struct Version: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// Store-defined raw representation. `nil` is `.none`.
    let rawValue: String?

    /// The token for an aggregate with no stored version yet.
    static let none = Version(rawValue: nil)

    init(rawValue: String?) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue ?? "<none>"
    }
}

// MARK: - Integer binding

extension Version {

    /// Builds a token from a store's integer counter (`nil` -> `.none`).
    init(versionInt: Int?) {
        self.rawValue = versionInt.map(String.init)
    }

    /// Builds a token from a known integer counter value.
    init(_ versionInt: Int) {
        self.rawValue = String(versionInt)
    }

    /// The integer counter, when the raw value parses as one; otherwise `nil`.
    var versionInt: Int? {
        rawValue.flatMap(Int.init)
    }
}
