//
//  VersionedModel.swift
//  ShowMenuBackend
//
//  The persisted side of the opaque optimistic-concurrency token.
//

/// The persisted counterpart of ``Version`` for stores that bind the opaque token
/// to a **monotonic integer**: the model carries the counter, the store's
/// check-and-set reads it, compares it, and writes `counter + 1`.
///
/// The protocol is store-agnostic on purpose — it says nothing about *where* the
/// counter lives (a document field, a SQL column, a dictionary entry), only that
/// the model exposes one. The Firestore adapter binds it in
/// `Firestore+Concurrency` (to an integer `version` document field); a future SQL
/// adapter could bind the same protocol to a `version` column.
///
/// A store with **no versioning mechanism simply doesn't conform**: ``DataSource``
/// ships default no-op check-and-set methods, so versioning is strictly opt-in
/// and un-versioned models keep working unchanged.
///
/// `version == nil` means the document predates versioning (or was just created
/// without one); the binding treats it as `Version.none`, so existing documents
/// adopt optimistic concurrency on their first write with **no data migration**.
protocol VersionedModel: Sendable {
    var version: Int? { get set }
}
