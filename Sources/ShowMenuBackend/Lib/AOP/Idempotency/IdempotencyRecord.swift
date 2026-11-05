//
//  IdempotencyRecord.swift
//  ShowMenuBackend
//
//  The persisted de-duplication record and the read-phase reservation outcome.
//

import Foundation

// MARK: - Status

/// Lifecycle of an idempotency record.
///
/// In the single-transaction Firestore binding only `.completed` is ever
/// committed (the record and the work commit together). `.inProgress` is part of
/// the protocol so the store stays binding-agnostic — a two-phase / SQL store, or
/// a crash remnant, can leave an in-progress marker that a later probe rejects.
enum IdempotencyStatus: String, Sendable, Codable {
    case inProgress
    case completed
}

// MARK: - Stored response

/// The captured outcome of the first successful execution — enough to reconstruct
/// an identical reply on replay.
///
/// At the `CommandHandler` altitude the meaningful part is `body` (the encoded
/// command `Result`); the decoded `Result` flows back through the same controller
/// path, which deterministically re-derives the HTTP status. `status` is retained
/// so an edge-level producer can record the exact HTTP status when it has it.
struct StoredResponse: Sendable, Codable, Equatable {

    /// Advisory HTTP-ish status the first call produced (e.g. 201 for a create).
    let status: Int

    /// The encoded command `Result` (canonical JSON).
    let body: Data

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

// MARK: - Record

/// A persisted de-duplication record: one per (scope+key), holding the request
/// fingerprint, the stored response (when completed), and TTL bookkeeping.
struct IdempotencyRecord: Sendable, Equatable {

    /// The scoped, hashed record identity (the store's document id).
    let id: String

    /// Digest of the originating request payload (mismatch ⇒ key misuse).
    let fingerprint: RequestFingerprint

    let status: IdempotencyStatus

    /// Present once `status == .completed`.
    let response: StoredResponse?

    let createdAt: Date

    /// When the record becomes eligible for cleanup. A probe past this instant
    /// treats the slot as empty (see ``IdempotencyReservation``).
    let expiresAt: Date
}

// MARK: - Reservation outcome (read phase)

/// The result of the store's read-phase probe (``IdempotencyStore/reserve``).
///
/// The probe never writes — Firestore forbids reads after writes, so the record
/// is only persisted later by ``IdempotencyStore/complete`` (write phase). When
/// the caller should proceed, it receives an opaque ``IdempotencyTicket`` to hand
/// back to `complete`, so the store need not be told the key/fingerprint twice.
enum IdempotencyReservation: Sendable {

    /// No usable record — run the work, then `complete(ticket:response:)`.
    case proceed(IdempotencyTicket)

    /// A completed record with a matching fingerprint exists — return its stored
    /// response without re-executing.
    case replay(StoredResponse)

    /// An in-progress record occupies the slot — reject as a concurrent
    /// duplicate (do not run the work).
    case inProgress

    /// A record exists but its fingerprint differs — same key, different body.
    case mismatch
}

/// An opaque proceed-token threaded from `reserve` to `complete`.
///
/// Carries the resolved identity + fingerprint and whether the slot was occupied
/// by an *expired* record, so `complete` can choose the right write (transactional
/// `create` for an empty slot — the in-flight unique guard — vs. overwrite for an
/// expired one). It is store-agnostic data; the decorator passes it through
/// without interpreting it.
struct IdempotencyTicket: Sendable {
    let id: String
    let fingerprint: RequestFingerprint
    /// True when an expired record physically occupies the slot.
    let overwriteExpired: Bool
}
