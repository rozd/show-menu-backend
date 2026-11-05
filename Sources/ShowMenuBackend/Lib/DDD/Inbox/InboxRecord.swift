//
//  InboxRecord.swift
//  ShowMenuBackend
//
//  The persisted processed-event marker and the read-phase reservation outcome.
//

import Foundation

// MARK: - Stored record

/// A persisted inbox record: one per (consumer, event), marking that the event
/// has been processed by this consumer.
struct InboxRecord: Sendable, Equatable {

    /// The per-consumer, per-event, scoped record identity (the store's
    /// document id). Derived from `consumer` type + `eventId`.
    let id: String

    /// When the event was marked as processed.
    let processedAt: Date

    /// When the record becomes eligible for cleanup. A probe past this instant
    /// treats the slot as empty (see ``InboxReservation``).
    let expiresAt: Date
}

// MARK: - Reservation outcome (read phase)

/// The result of the store's read-phase probe (``InboxStore/reserve``).
///
/// The probe never writes — the contract is strictly read-then-write (see
/// ``InboxStore``), so the record is only persisted later by
/// ``InboxStore/complete`` (write phase). When the caller should proceed,
/// it receives an opaque ``InboxTicket`` to hand back to `complete`, so the
/// store need not be told the id twice.
enum InboxReservation: Sendable {

    /// No usable record — run the handler, then `complete(ticket:)`.
    case proceed(InboxTicket)

    /// A processed record already exists — return without running the handler
    /// (idempotency).
    case alreadyProcessed
}

/// An opaque proceed-token threaded from `reserve` to `complete`.
///
/// Carries the resolved identity and whether the slot was occupied by an
/// *expired* record, so `complete` can choose the right write (transactional
/// `create` for an empty slot — the in-flight unique guard — vs. overwrite
/// for an expired one). It is store-agnostic data; the mixin passes it through
/// without interpreting it.
struct InboxTicket: Sendable {
    let id: String
    /// True when an expired record physically occupies the slot.
    let overwriteExpired: Bool
}
