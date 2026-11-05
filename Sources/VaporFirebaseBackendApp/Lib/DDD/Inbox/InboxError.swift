//
//  InboxError.swift
//  VaporFirebaseBackendApp
//
//  Errors raised by the inbox subsystem.
//

/// Errors surfaced by the inbox layer. Each represents a condition that should
/// abort the handler's work, but does not map to an HTTP edge status (inbox
/// de-duplication is internal, transparent to clients).
enum InboxError: Error, Equatable {

    /// A processed inbox record could not be decoded — the slot is corrupted
    /// (hand-edited, or a pre-schema record). Either is corrupt server-side state
    /// (the write path always stores a valid record), not client misuse. The
    /// handler does not run; the transaction aborts.
    case corruptRecord(id: String)

    /// Lost the record-insert race to a concurrent delivery of the same event:
    /// the store's `create` hit ALREADY_EXISTS (`exists == false` precondition),
    /// meaning the winner's marker committed first. The store maps that to this
    /// error. In practice Firestore buffers the `create` and enforces the
    /// precondition at commit, where the transaction runner retries and the
    /// retry's `reserve` skips silently as `.alreadyProcessed`; a commit-time
    /// conflict that outlasts every attempt escapes the unit of work as a mapped
    /// `FirestoreError`, not this case. Either way the outcome is correct (the
    /// winner did the work); the dispatcher logs and swallows the error.
    case duplicateEvent(id: String)
}
