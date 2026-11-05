//
//  IdempotencyConfiguration.swift
//  ShowMenuBackend
//
//  The tunable policy of the idempotency subsystem: key scope, retention, and
//  the in-flight-duplicate strategy.
//

import Foundation
import Crypto

// MARK: - Key scope

/// How broadly a single `Idempotency-Key` value is interpreted — i.e. what else,
/// besides the raw key, distinguishes one record from another.
///
/// Default: ``actorAndCommandType``. Scoping by command type stops a key reused
/// across *different* operations from colliding (and replaying the wrong
/// response); including the actor stops one principal's key from shadowing
/// another's. Drop to ``commandType`` or ``global`` only when a key is already
/// guaranteed unique by the client across that wider space.
enum IdempotencyScope: Sendable {

    /// The raw key alone identifies the record.
    case global

    /// Key + command type.
    case commandType

    /// Key + command type + principal id (anonymous principals share a bucket).
    case actorAndCommandType

    /// Derives the stable, store-safe record id for this scope.
    ///
    /// The scope discriminator and key are hashed (SHA-256) into a fixed,
    /// path-safe document id — the raw key may contain characters Firestore
    /// rejects in a document id (e.g. `/`), and hashing also avoids leaking the
    /// key value into storage keys.
    func recordId(key: IdempotencyKey, commandType: String, principalId: String?) -> String {
        let discriminator: String
        switch self {
        case .global:
            discriminator = "*"
        case .commandType:
            discriminator = commandType
        case .actorAndCommandType:
            discriminator = "\(principalId ?? "anonymous")::\(commandType)"
        }
        // U+0000 separates the fields so they can't run together ambiguously.
        let composed = "\(discriminator)\u{0}\(key.rawValue)"
        let digest = SHA256.hash(data: Data(composed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - In-flight strategy

/// What to do when a duplicate arrives while the original request is still in
/// flight (an in-progress record, or a lost commit race after the runner's
/// retries).
///
/// Default — and the only behaviour implemented for the stateless Cloud Run +
/// Firestore binding — is ``rejectConflict``: the duplicate is rejected with
/// ``IdempotencyError/requestInProgress(key:)`` (→ `409`) and the client retries,
/// by which point the original has usually committed and the retry *replays*.
///
/// *Block-and-wait* was considered and deliberately left out: a stateless
/// instance has no cheap primitive to await another instance's transaction, and
/// holding the connection open risks head-of-line blocking. Reject-and-retry is
/// the idiomatic REST idempotency behaviour. The type stays an enum so the policy
/// is explicit at the call site and a future binding can add a waiting strategy.
enum InFlightStrategy: Sendable {
    case rejectConflict
}

// MARK: - Configuration

/// Aggregate policy for an ``IdempotentCommandHandler``.
struct IdempotencyConfiguration: Sendable {

    /// How a key is scoped into a record id. Default ``IdempotencyScope/actorAndCommandType``.
    var scope: IdempotencyScope

    /// How long a completed record is retained before it is eligible for cleanup
    /// and a probe treats the slot as empty. Default 24h.
    var ttl: TimeInterval

    /// Concurrent-duplicate behaviour. Default ``InFlightStrategy/rejectConflict``.
    var inFlight: InFlightStrategy

    init(
        scope: IdempotencyScope = .actorAndCommandType,
        ttl: TimeInterval = 24 * 60 * 60,
        inFlight: InFlightStrategy = .rejectConflict
    ) {
        self.scope = scope
        self.ttl = ttl
        self.inFlight = inFlight
    }

    static let `default` = IdempotencyConfiguration()
}
