//
//  InboxConfiguration.swift
//  VaporFirebaseBackendApp
//
//  The tunable policy of the inbox subsystem: retention and record-id derivation.
//

import Foundation
import Crypto

// MARK: - Record ID

/// Derives stable, store-safe record ids for per-consumer inbox entries.
enum InboxRecordId {

    /// The per-consumer, per-event record id for the given event id.
    ///
    /// The record id is consumer-specific (keyed on the handler's concrete
    /// `Params` type name) and event-specific (keyed on the `eventId`), so the
    /// same event processed by two different consumer command types both process
    /// once.
    ///
    /// Consumer type names and event ids are hashed (SHA-256) into a fixed,
    /// path-safe record id — the type name and UUID may contain characters a
    /// store rejects in a document id / primary key (e.g. `/` or `<`), and
    /// hashing also avoids leaking them into storage keys.
    static func derive(consumer: String, eventId: UUID) -> String {
        // U+0000 separates the fields so they can't run together ambiguously.
        let composed = "\(consumer)\u{0}\(eventId.uuidString)"
        let digest = SHA256.hash(data: Data(composed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Configuration

/// Aggregate policy for an ``InboxedCommandHandler``.
struct InboxConfiguration: Sendable {

    /// How long a processed record is retained before it is eligible for cleanup
    /// and a probe treats the slot as empty. Default 7 days (the marker only needs
    /// to outlive the redelivery window; outbox retention is typically 7 days too).
    var ttl: TimeInterval

    init(ttl: TimeInterval = 7 * 24 * 60 * 60) {
        self.ttl = ttl
    }

    static let `default` = InboxConfiguration()
}
