//
//  InboxError.swift
//  ShowMenuBackend
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
    /// the winner's marker committed first, so this transaction — work included —
    /// is aborted. Correct by outcome (the winner did the work); the dispatcher
    /// logs and swallows it, and there is no queue retry for the loser, by design.
    case duplicateEvent(id: String)
}
