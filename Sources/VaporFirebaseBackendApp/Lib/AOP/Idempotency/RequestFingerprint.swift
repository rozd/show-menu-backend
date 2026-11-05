//
//  RequestFingerprint.swift
//  VaporFirebaseBackendApp
//
//  A stable digest of a request payload, for same-key-different-body detection.
//

import Foundation
import Crypto

/// A stable, content-addressable digest of a command's payload.
///
/// Stored alongside the idempotency record so a *replay* can verify the retry
/// carries the **same** request body. A key reused with a different body is
/// client misuse (``IdempotencyError/fingerprintMismatch(key:)``) — without this
/// check, a second, *different* request would silently receive the first
/// request's stored response.
///
/// The digest is a SHA-256 over a canonical JSON encoding (sorted keys, so field
/// order is irrelevant), making it deterministic across processes and retries.
struct RequestFingerprint: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {

    /// Lower-case hex SHA-256.
    let value: String

    init(value: String) {
        self.value = value
    }

    /// Derives a fingerprint from any `Encodable` payload using a canonical
    /// (sorted-key) JSON encoding.
    init<Payload: Encodable>(payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let digest = SHA256.hash(data: data)
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }

    var description: String { value }
}
